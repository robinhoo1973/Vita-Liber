#if os(iOS) || os(macOS)
import Foundation
import Testing
import GRDB
@testable import Domain
@testable import Infrastructure

/// 全链升级金样（2026-09-16 业主裁定「补全 v1→v27 全链」）：**v1 基线快照 → 逐步跑到最新**
/// = 全新库基线。与 v24 金样（`SchemaV25GoldenTests`）互补——它覆盖 v24 起，本套件把
/// 覆盖面下探到 v1（v2..v23 的历史增列/增表首次进入自动化验证）。
///
/// v1（flutter JSON）半场已由 `GoldenMigrationTests` 覆盖（`flutter_backup_v1.json` 金样 +
/// `MigrationEngine.migrate` 正负例）——v1 无 SQL 库，升级即「JSON 导入 → 建 v2 全量表」。
///
/// 夹具 `schema_v1_baseline.sql` = 提交 `a7a45e7`（M0 全量建表落地）冻结的 `SchemaV2.ddl` 全文，
/// 即 `SchemaMigrations.baselineVersion = 1` 对应的库形态（steps 从 v2 起，两者互补）。
/// 修复的历史教训（CI 34020363188 同族）：**合成老库必须完整**——只含部分表时
/// v6 的 FTS delete-all、v8 的 encounter ALTER 会撞 no such table（错误来自夹具不完整，
/// 而非真实 v2 库；真实 v2 库含全部 33 表）。
@Suite("SU-M0-GOLDEN · v2→最新全链升级 = 全新库基线")
struct SchemaChainGoldenTests {
    static let fixture = Bundle.module.bundlePath + "/Fixtures/schema_v1_baseline.sql"

    /// 各版本步的代表物（v3..v28 覆盖抽样：新增表 / 增列 / 索引 / FTS 重建）。
    static let tables = [
        "local_owner", "patient_profile", "encounter", "prescription", "prescription_line",
        "claim_item", "claim_line", "document_file", "document_fts", "document_fts_2gram",
        "stock_lot", "dose_lot_allocation", "metric_sample", "guideline_source", "alert_event",
        "observation", "reminder", "notification_state", "voice_note",
        "hospitalization", "diagnosis", "exam_report", "lab_report", "lab_result",
        "health_exam", "clinical_conclusion", "surgery", "treatment_record",
        "ocr_card_commit", "pending_card", "hk_import_status",
    ]

    /// v1 老库：冻结快照 + `PRAGMA user_version = 1`（**必须为 1**——`pending(from:)` 取
    /// `version > current`，写 2 会跳过 v2 步（metric-reference-band 增列），链条从起点即错）
    /// + 一位成员（跨步的 REFERENCES 需要）。
    /// 必须用 `GRDBStore.configuration()`（注册 bigrams()、开外键，与生产库同形）。
    static func legacyV2Database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(configuration: GRDBStore.configuration())
        let patient = UUID()
        let ddl = String(decoding: try Data(contentsOf: URL(fileURLWithPath: Self.fixture)), as: UTF8.self)
        try queue.write { db in
            try db.execute(sql: ddl)
            try db.execute(sql: "PRAGMA user_version = 1")
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, 'A', 'self', 0, 0)
                """, arguments: [patient.uuidString])
        }
        return queue
    }

    private static func columns(_ db: Database, _ table: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?) ORDER BY name", arguments: [table])
    }

    @Test("v2 老库跑完整链：版本推进到最新 + 全部代表表存在")
    func 全链升级到最新() throws {
        let queue = try Self.legacyV2Database()
        _ = try GRDBStore(writer: queue)   // 跑 v2..v29
        let version = try queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1
        }
        #expect(version == SchemaMigrations.latestVersion, "老库必须推进到账本最新版本")

        let existing = try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
        }
        for table in Self.tables {
            #expect(existing.contains(table), "v2→最新链缺表：\(table)")
        }
    }

    @Test("升级终态 ⊇ 全新库基线列集（v2..v29 的增列/增表全部落地）")
    func 列集覆盖基线() throws {
        let legacy = try Self.legacyV2Database()
        _ = try GRDBStore(writer: legacy)
        let fresh = try GRDBStore.inMemory()

        for table in Self.tables {
            let upgraded = Set(try legacy.read { try Self.columns($0, table) })
            let baseline = Set(try fresh.writer.read { try Self.columns($0, table) })
            // 单向包含（本机 sqlite3 全链预演校准）：升级只需保证新基线所需列齐备；
            // 老库可保留历史列（实证：v1 audit_event 的 actor_member_id/entity_id/
            // occurred_at 为旧命名，基线改名后旧列留存——审计表只 INSERT，多列无害）。
            #expect(baseline.isSubset(of: upgraded),
                    "\(table) 缺基线列：\(baseline.subtracting(upgraded).sorted())")
        }
    }

    @Test("v28 索引在升级库中同样建立（迁移与基线同形）")
    func 新索引随链建立() throws {
        let queue = try Self.legacyV2Database()
        _ = try GRDBStore(writer: queue)
        let names = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='metric_sample'")
        }
        #expect(names.contains("idx_metric_timeline"))
        #expect(names.contains("idx_metric_latest"))
    }

    @Test("全链后二次装配幂等（重复启动不崩）")
    func 二次装配幂等() throws {
        let queue = try Self.legacyV2Database()
        _ = try GRDBStore(writer: queue)
        _ = try GRDBStore(writer: queue)   // 第二次装配不得抛错
    }
}
#endif
