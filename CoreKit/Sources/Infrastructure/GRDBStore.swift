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
    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try writer.write { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if version == 0 {
                try db.execute(sql: MigrationEngine.schemaV1)
                try db.execute(sql: "PRAGMA user_version = 1")
            }
            // version > 0：已建库——迁移按 SchemaMigrator 版本序列（M1.5 后批）
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
                  (id, display_name, relation, gender, birth_date, note, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    profile.id.uuidString, profile.displayName, profile.relation,
                    profile.gender, profile.birthDate, profile.note,
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
