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
    static var fixture: String { TestFixtures.path("schema_v1_baseline.sql") }

    /// 各版本步的代表物（v3..v28 覆盖抽样：新增表 / 增列 / 索引 / FTS 重建）。
    static let tables = [
        "local_owner", "patient_profile", "encounter", "prescription", "prescription_line",
        "claim_item", "claim_line", "document_file", "document_fts", "document_fts_2gram",
        "stock_lot", "dose_lot_allocation", "metric_sample", "guideline_source", "alert_event",
        "observation", "reminder", "notification_state", "voice_note",
        "hospitalization", "diagnosis", "exam_report", "lab_report", "lab_result",
        "health_exam", "clinical_conclusion", "surgery", "treatment_record",
        "ocr_card_commit", "pending_card", "hk_import_status",
        "lexicon_term",
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
    /// 原名：全链升级到最新
    func fullChainUpgradesToLatest() throws {
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
    /// 原名：列集覆盖基线
    func columnSetCoversBaseline() throws {
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
    /// 原名：新索引随链建立
    func newIndexesCreatedAlongChain() throws {
        let queue = try Self.legacyV2Database()
        _ = try GRDBStore(writer: queue)
        let names = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='metric_sample'")
        }
        #expect(names.contains("idx_metric_timeline"))
        #expect(names.contains("idx_metric_latest"))
    }

    @Test("全链后二次装配幂等（重复启动不崩）")
    /// 原名：二次装配幂等
    func secondAssemblyIdempotent() throws {
        let queue = try Self.legacyV2Database()
        _ = try GRDBStore(writer: queue)
        _ = try GRDBStore(writer: queue)   // 第二次装配不得抛错
    }

    /// v33 升级链修复的**写入型**探针（2026-10-10 审查轮教训:此前金样只断言
    /// 列/表存在、从不写这些表,三条链级缺陷——v13 悬空 FK、v29 遗留
    /// occurred_at NOT NULL、缺索引——才会在真实升级库上潜伏至今）。
    @Test("升级链写入探针：审计写 / 剂量批分配写 / 外键归属 / 缺索引补齐")
    func upgradeChainWriteProbes() throws {
        let queue = try Self.legacyV2Database()
        _ = try GRDBStore(writer: queue)
        let probes = try queue.read { db -> (audit: Int, foreignParents: [[String]], indexes: Set<String>, auditColumns: [String]) in
            let patient = try String.fetchOne(db, sql: "SELECT id FROM patient_profile LIMIT 1") ?? ""
            try db.execute(sql: """
                INSERT INTO medication (id, patient_id, generic_name, unit_kind, created_at, updated_at)
                VALUES ('m1', ?, '阿司匹林', 'tablet', 0, 0)
                """, arguments: [patient])
            try db.execute(sql: """
                INSERT INTO medication_plan (id, patient_id, medication_id, schedule_json, start_date, created_at, updated_at)
                VALUES ('p1', ?, 'm1', '{}', 0, 0, 0)
                """, arguments: [patient])
            // ① 审计写（AuditLogWriter 同形态列集）——v29 遗留 occurred_at 的直接受害者
            try db.execute(sql: """
                INSERT INTO audit_event (id, actor_local, action, entity_type, entity_id_hash, at, meta_json)
                VALUES ('a1', 'owner', 'confirm', 'dose', NULL, 1.0, '{}')
                """)
            // ② 剂量行 + 批分配真实写入——v13 悬空 FK 的直接受害者（BR-004 台账）
            try db.execute(sql: """
                INSERT INTO medication_dose_log (id, plan_id, scheduled_for, dose_units, delivery_state)
                VALUES ('d1', 'p1', 0, 1, 'delivered')
                """)
            try db.execute(sql: """
                INSERT INTO stock_lot (id, patient_id, medication_id, total_units, unit_kind,
                                       remaining_plan_units, remaining_confirmed_units,
                                       status, last_reconciled_at)
                VALUES ('l1', ?, 'm1', 10, 'tablet', 10, 0, 'active', 0)
                """, arguments: [patient])
            try db.execute(sql: """
                INSERT INTO dose_lot_allocation (dose_log_id, stock_lot_id, planned_units, confirmed_units)
                VALUES ('d1', 'l1', 1, 0)
                """)
            // ③ 外键归属 = 正名（悬空修复的结构证据）
            var parents: [[String]] = []
            for (table, column) in [("dose_lot_allocation", "dose_log_id"),
                                    ("notification_delivery", "dose_log_id")] {
                parents.append(try String.fetchAll(db, sql: """
                    SELECT "table" FROM pragma_foreign_key_list(?) WHERE "from" = ?
                    """, arguments: [table, column]))
            }
            let indexes = Set(try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type='index'"))
            let auditColumns = try String.fetchAll(
                db, sql: "SELECT name FROM pragma_table_info('audit_event')")
            let auditCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM audit_event") ?? -1
            return (auditCount, parents, indexes, auditColumns)
        }
        #expect(probes.audit == 1, "审计写必须落库（v29 遗留 occurred_at 已退役）")
        #expect(!probes.auditColumns.contains("occurred_at"), "老列必须退役")
        #expect(probes.foreignParents == [["medication_dose_log"], ["medication_dose_log"]],
                "子表 FK 必须指回正名（v13 悬空已修）：\(probes.foreignParents)")
        #expect(probes.indexes.contains("idx_sent_message_patient"))
        #expect(probes.indexes.contains("idx_metric_sample_lab_report"))
        #expect(probes.indexes.contains("idx_metric_sample_health_exam"))
    }
}
#endif
