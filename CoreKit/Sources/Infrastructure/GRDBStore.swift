// 平台守卫必须与 Package.swift 的 `.when(platforms: [.iOS, .macOS])` 严格镜像。
// 不用 `#if canImport(GRDB)`：实测在 Linux 上 canImport(GRDB) 返回 true（模块可发现），
// 随后却因 GRDB 自身的 CSQLite 子模块无法构建而报 "missing required module 'CSQLite'"
// —— canImport 探测的是模块可见性，不是可链接性。
#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

/// M0 · SchemaV1 装配（tech-spec §4.3 DDL / §4.4 并发模型 / ADR-001）
///
/// **平台边界（ERR#8）**：GRDB 仅在 iOS/macOS 链接。Linux 发行版 libsqlite3 编译时
/// 未启用 `SQLITE_ENABLE_SNAPSHOT`，缺 `sqlite3_snapshot_*` 符号导致链接失败；而本
/// 产品目标平台是 iOS，Apple 平台 SQLite 具备该能力。故 Package.swift 用
/// `.when(platforms: [.iOS, .macOS])` 条件依赖，Linux 侧只跑 Domain 层门禁，
/// 本文件整体被 `#if canImport(GRDB)` 编译排除——不是降级，是平台正确性。
public struct GRDBStore {
    /// §4.4：仓储面向 `any DatabaseWriter`（tech V3.24 修正条——不得写死 DatabaseQueue）。
    /// 生产装配注入共享 `DatabasePool`(WAL)；测试/Preview 注入内存 `DatabaseQueue`。
    public let writer: any DatabaseWriter

    /// 外键必须落在**连接配置**上。旧实现 `var config = Configuration(); ...; _ = config`
    /// 把配置整个丢弃、改用事后 `PRAGMA foreign_keys = ON`——那是 per-connection 的，
    /// 对多连接的 DatabasePool 只作用于执行它的那一条连接，属于潜在越权写入风险。
    /// 同时注册 bigrams() SQL 函数（FTS 2-gram 影子表触发器依赖，V3.44）——
    /// prepareDatabase 保证 DatabasePool 的每条连接都注册。
    public static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.add(function: DatabaseFunction("bigrams", argumentCount: 1, pure: true) { values in
                guard let text = String.fromDatabaseValue(values[0]), text.isEmpty == false else { return "" }
                return SearchRules.bigrams(text).joined(separator: " ")
            })
        }
        return config
    }

    /// 生产装配：文件库 + WAL（§4.4 唯一共享 DatabasePool，并发读/串行写）
    public static func pool(at path: String) throws -> GRDBStore {
        try GRDBStore(writer: DatabasePool(path: path, configuration: configuration()))
    }

    /// 测试与 Preview 装配：内存库（WAL 不适用于内存库，按 GRDB 惯例用 DatabaseQueue）
    public static func inMemory() throws -> GRDBStore {
        try GRDBStore(writer: DatabaseQueue(configuration: configuration()))
    }

    /// 评审 S 级修正：建库以 PRAGMA user_version 版本序列门控——
    /// 旧实现每次启动无条件执行全量 DDL，持久库二次启动即「表已存在」崩溃
    /// （测试全用内存库从未暴露）。v1 建库一次，后续版本经 DatabaseMigrator 迁移。
    /// 建库 + 迁移一体：`PRAGMA user_version` 是唯一版本账本（理由见 SchemaMigrations 头注）。
    /// - v0（全新库）：跑 baseline 全量 DDL，直接落到 `latestVersion`——baseline 已含最新列，
    ///   无需再重放增量步骤（幂等守卫仍保证重放无害）。
    /// - v>0（既有库）：只跑 `pending(from:)` 的增量步骤，逐步推进 user_version。
    ///
    /// 旧实现在 `version > 0` 分支什么都不做，等于**新列永远不会到达已装机的库**；
    /// 这是滞留项 #7 的实质内容，随本批清偿。
    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try writer.write { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if version == 0 {
                try db.execute(sql: MigrationEngine.schemaV1)
                // PRAGMA 不接受占位参数，版本号来自本仓常量而非外部输入
                try db.execute(sql: "PRAGMA user_version = \(SchemaMigrations.latestVersion)")
                return
            }
        }
        try migrateIncremental(writer: writer)
    }

    /// 既有库增量迁移：在**事务外**执行并临时关闭外键检查。
    ///
    /// 为什么不能沿用单事务：v13 是 SQLite 表重建（建新表→拷贝→换名），
    /// 老库 dose_log 可能携带孤儿行（plan 已删）——重建 INSERT 会即时触发 FK
    /// 违规（OR IGNORE 不覆盖 FOREIGN KEY 约束），迁移整体回滚、升级卡死
    /// （CI 34020363188 实证）。`PRAGMA foreign_keys` 在事务内是 no-op，
    /// 故按 SQLite 官方表重建流程：事务外关闭 FK → 迁移 → 重新开启；
    /// 重建后 FK 声明仍在（运行时执法），历史孤儿行得以保留（数据保留原则）。
    /// 原子性由「每步幂等/可恢复 + user_version 逐步推进」保证：
    /// - v13/v15 为**代码迁移**（本文件私有实现）——v13 用 rename-first 可恢复
    ///   重建（任一崩溃点重放安全，绝不 DROP 唯一数据副本）；v15 原地重算
    ///   逻辑剂量 id（已决议行保留、事实不丢，避免 DELETE 全清造成的送达
    ///   证据灭失与重建后重复行/双扣）。
    /// - 纯 SQL 步沿用 addColumnParts 幂等守卫。
    /// - user_version 只随成功步骤推进；崩溃重放从最近成功版本续跑。
    private func migrateIncremental(writer: any DatabaseWriter) throws {
        try writer.writeWithoutTransaction { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            guard version != SchemaMigrations.latestVersion else { return }
            if version > SchemaMigrations.latestVersion {
                // 前向版本守卫：更新的 schema 被旧二进制打开，静默读写会以旧列假设
                // 破坏数据——必须显式失败进入 SL-15 降级链（只读降级/锁死页），
                // 不得当作「无需迁移」放行。
                throw MigrationError.schemaTooNew(found: version, supported: SchemaMigrations.latestVersion)
            }
            guard version > 0 else { return }
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }   // try?-ok: 兜底复位；主路径见循环后的显式校验
            for step in SchemaMigrations.pending(from: version) {
                switch step.version {
                case 13:
                    try Self.rebuildDoseLogWithFK(db)
                case 15:
                    try Self.recomputeLogicalDoseIds(db)
                default:
                    for statement in SchemaMigrations.statements(step.sql) {
                        // 幂等：baseline 已含该列的库上重放 ADD COLUMN 会报 duplicate column
                        if let parts = SchemaMigrations.addColumnParts(statement) {
                            let exists = try Int.fetchOne(db, sql: """
                                SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = ?
                                """, arguments: [parts.table, parts.column]) ?? 0
                            if exists > 0 { continue }
                        }
                        try db.execute(sql: statement)
                    }
                }
                try db.execute(sql: "PRAGMA user_version = \(step.version)")
            }
            // 显式复位并校验：迁移后连接必须回到 FK 执法开启——静默留在 OFF 会让
            // 后续所有写入失去引用完整性（L0 门禁断言读的是 reader 连接，检测不到）。
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            guard (try Int.fetchOne(db, sql: "PRAGMA foreign_keys")) == 1 else {
                throw MigrationError.foreignKeysNotReenabled
            }
        }
    }

    /// v13 代码迁移：legacy 无 FK 的 medication_dose_log 表重建补 REFERENCES。
    /// rename-first 可恢复序列——任一语句后崩溃，重放从遗留状态续跑：
    ///   ① RENAME dose_log → dose_log_old（原子）
    ///   ② CREATE 新表（带 plan_id REFERENCES）
    ///   ③ INSERT OR IGNORE 拷贝（OR IGNORE 保住历史孤儿行：数据保留原则）
    ///   ④ DROP dose_log_old
    /// 崩溃点分析：①后崩溃 → 重放见 _old 在、新表缺 → 从②续；②/③后崩溃 →
    /// IF NOT EXISTS / OR IGNORE 幂等重放；④后崩溃 → 重放见新表在、_old 缺 →
    /// 视为已完成（同库重放只在 user_version 未推进时发生，语义安全）。
    private static func rebuildDoseLogWithFK(_ db: Database) throws {
        let hasOld = try tableExists(db, "medication_dose_log_old")
        let hasCurrent = try tableExists(db, "medication_dose_log")
        if !hasOld && hasCurrent {
            try db.execute(sql: "ALTER TABLE medication_dose_log RENAME TO medication_dose_log_old")
        }
        guard try tableExists(db, "medication_dose_log_old") else {
            // 两表皆无：基线库不重放本步（全新库直达 latestVersion）——防御性放行
            return
        }
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS medication_dose_log (
              id TEXT PRIMARY KEY, plan_id TEXT NOT NULL REFERENCES medication_plan(id),
              scheduled_for REAL NOT NULL,
              dose_units REAL NOT NULL DEFAULT 1,
              delivery_state TEXT NOT NULL CHECK(delivery_state IN ('planned','sent','delivered','failed')),
              delivered_at REAL, user_action TEXT CHECK(user_action IN
                ('taken','snoozed','skipped','missed','discomfort') OR user_action IS NULL),
              acted_at REAL, snooze_until REAL, note TEXT);
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO medication_dose_log
              (id, plan_id, scheduled_for, dose_units, delivery_state,
               delivered_at, user_action, acted_at, snooze_until, note)
            SELECT id, plan_id, scheduled_for, dose_units, delivery_state,
                   delivered_at, user_action, acted_at, snooze_until, note
            FROM medication_dose_log_old;
            """)
        try db.execute(sql: "DROP TABLE medication_dose_log_old")
    }

    /// v15 代码迁移：剂量行 id 由绝对 epoch 迁移为逻辑身份（day+ordinal，D5）。
    /// 原地重算而非 DELETE-重物化：
    /// - 已决议行（用户动作是事实）与已送达证据（delivered_at/delivery_state）
    ///   全程保留——DELETE 方案会把 delivered≠taken 事实链抹掉；
    /// - 重算后的逻辑 id 让后续物化窗口 ON CONFLICT 精确命中，杜绝
    ///   「时区变化后 ±60s 守卫失效 → 重复行 → materializeMissed 双扣」；
    /// - 无法重算的未决议行（计划已删/日程损坏）沿用原语义清除——它们不会被
    ///   物化窗口重建，留存只会重复；无法重算的已决议行保留原 id（事实优先）。
    private static func recomputeLogicalDoseIds(_ db: Database) throws {
        let calendar = Calendar.current
        // 第四轮全仓审查效率修复（5WHY）：原实现每条 dose_log 行内嵌套查
        // medication_plan（N+1）+ 行内新建 JSONDecoder——长期用药用户数千至
        // 数万行时启动迁移按行数线性放大。计划表一次性读入字典（计划数
        // 远小于剂量行数），JSONDecoder 提到循环外复用（PDFExportService
        // 同仓先例）。语义不变：无法匹配计划的行为沿用原降级路径。
        let decoder = JSONDecoder()
        let planRows = try Row.fetchAll(db, sql: """
            SELECT id, schedule_json, start_date FROM medication_plan
            """)
        var plans: [String: (schedule: MedicationSchedule, startDate: Date)] = [:]
        for plan in planRows {
            guard let planId = plan["id"] as String?,
                  let start = plan["start_date"] as Double? else { continue }
            let schedule: MedicationSchedule
            if let json = (plan["schedule_json"] as String?)?.data(using: .utf8),
               let decoded = try? decoder.decode(MedicationSchedule.self, from: json) {   // try?-ok: 单条计划日程损坏沿用 asNeeded 降级（与原逐行语义一致）
                schedule = decoded
            } else {
                schedule = MedicationSchedule.asNeeded
            }
            plans[planId] = (schedule, Date(timeIntervalSince1970: start))
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, plan_id, scheduled_for, user_action FROM medication_dose_log
            """)
        for row in rows {
            let currentId = row["id"] as String
            // 逻辑 id 形态 = dose-{planUUID}-{day}-{ordinal}（5 段）；legacy = 4 段
            guard currentId.split(separator: "-").count == 4 else { continue }
            let planId = row["plan_id"] as String
            let scheduledFor = row["scheduled_for"] as Double
            var recomputed: String?
            if let plan = plans[planId] {
                let startDate = plan.startDate
                let time = Date(timeIntervalSince1970: scheduledFor)
                let dayOf = calendar.dateComponents([.day],
                    from: calendar.startOfDay(for: startDate),
                    to: calendar.startOfDay(for: time)).day ?? 0
                let fromDay = max(1, dayOf - 2)
                let (doses, _) = DoseScheduleEngine.doses(
                    schedule: plan.schedule, planId: UUID(uuidString: planId) ?? UUID(),
                    startDate: startDate, fromDay: fromDay, toDay: fromDay + 4,
                    calendar: calendar)
                if let nearest = doses.min(by: {
                    abs($0.dueAt.timeIntervalSince(time)) < abs($1.dueAt.timeIntervalSince(time))
                }) {
                    recomputed = nearest.notifyId
                }
            }
            if let newId = recomputed, newId != currentId {
                do {
                    // 第六轮全仓审查修复：id 原地改写必须先同步引用行——本迁移
                    // 在 foreign_keys=OFF 下运行，无级联更新，原实现让
                    // dose_lot_allocation/notification_delivery 的历史行悬空
                    // （引用不存在的剂量 id，账本/送达证据链断裂且无任何报错）
                    try db.execute(sql: "UPDATE dose_lot_allocation SET dose_log_id = ? WHERE dose_log_id = ?",
                                   arguments: [newId, currentId])
                    try db.execute(sql: "UPDATE notification_delivery SET dose_log_id = ? WHERE dose_log_id = ?",
                                   arguments: [newId, currentId])
                    try db.execute(sql: "UPDATE medication_dose_log SET id = ? WHERE id = ?",
                                   arguments: [newId, currentId])
                }
                catch {
                    // PK 冲突：同一逻辑身份已被另一行占用（历史重复行）——
                    // 未决议行清除（物化窗口会以正确身份重建），已决议行保留原 id
                    if (row["user_action"] as String?) == nil {
                        try db.execute(sql: "DELETE FROM dose_lot_allocation WHERE dose_log_id = ?",
                                       arguments: [currentId])
                        try db.execute(sql: "DELETE FROM medication_dose_log WHERE id = ?",
                                       arguments: [currentId])
                    }
                }
            }
        }
        // 残余清除：无法重算的未决议行（计划已删/日程损坏/旧 epoch id）——
        // 保留会与逻辑 id 物化窗口重复计账，且物化只覆盖 active 计划，不会被重建。
        // GLOB 判定：逻辑 id = dose-{uuid}-{day}-{ordinal}（前缀 dose- + 4 段），
        // 其余形态（旧 epoch 三段 id / 随机 UUID 补录 id）一律视为不可重算残留。
        try db.execute(sql: """
            DELETE FROM medication_dose_log
            WHERE user_action IS NULL AND id NOT GLOB 'dose-*-*-*-*'
            """)
    }

    private static func tableExists(_ db: Database, _ name: String) throws -> Bool {
        (try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?
            """, arguments: [name])) ?? 0 > 0
    }

    public enum MigrationError: Error, Equatable, CustomStringConvertible {
        case schemaTooNew(found: Int, supported: Int)
        case foreignKeysNotReenabled
        public var description: String {
            switch self {
            case .schemaTooNew(let found, let supported):
                return "数据库 schema 版本 \(found) 高于当前二进制支持的 \(supported)——须更新 App（SL-15 降级链）"
            case .foreignKeysNotReenabled:
                return "迁移后 PRAGMA foreign_keys 复位失败"
            }
        }
    }

    /// 列名显式书写：位置参数 `VALUES (?,?)` 会在 §4.3 DDL 增列时静默错位。
    /// v2 全表（V3.40）后 patient_profile 有 NOT NULL 的 relation/created_at/updated_at，
    /// 必须随实体全量入库。
    public func insert(profile: PatientProfile) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO patient_profile
                  (id, display_name, relation, gender, birth_date, blood_type, id_no,
                   insurance_no, note, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    profile.id.uuidString, profile.displayName, profile.relation,
                    profile.gender, profile.birthDate, profile.bloodType,
                    profile.idNo, profile.insuranceNo, profile.note,
                    profile.createdAt, profile.updatedAt,
                ])
        }
    }

    /// TC-M0-06 运行时断言用：`PRAGMA foreign_keys` 是否为 1。
    /// 读失败保守返回 false（不用 `try?`——tech-spec §7 红线）。
    /// 用 `Int.fetchOne` 而非 `(row[0] as Int)`：GRDB Row 下标返回 DatabaseValue，
    /// 强转 Int 有运行时 trap 风险且 do/catch 捕获不到（评审 S1-2）。
    public var foreignKeysOn: Bool {
        do {
            return try writer.read { db -> Bool in
                (try Int.fetchOne(db, sql: "PRAGMA foreign_keys")) == 1
            }
        } catch {
            return false
        }
    }
}
#endif
