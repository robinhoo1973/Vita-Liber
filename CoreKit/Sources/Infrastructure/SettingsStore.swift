#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F14 设置存储（§5.28）：app_settings 表 + 键枚举单一事实源。
/// 只存非默认覆盖；读路径回退默认值（SettingsRules.resolved）。
/// 审计：设置变更写 audit_event（action='grant_change' 类语义见 App 层接线）。
public actor SettingsStore: SettingsStoring {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public func value(for key: AppSettingKey) async throws -> String {
        try await writer.read { db in
            let stored = try String.fetchOne(db, sql: """
                SELECT value FROM app_settings WHERE key = ?
                """, arguments: [key.rawValue])
            return SettingsRules.resolved(stored, key: key)
        }
    }

    public func set(_ value: String, for key: AppSettingKey) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO app_settings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [key.rawValue, value])
        }
    }

    /// 全量读取（一次查询）——审查修复：原 App 层逐键 SELECT（~35 次
    /// 串行 actor 往返 + 事务）拖慢启动路径与语言切换
    public func allValues() async throws -> [AppSettingKey: String] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM app_settings")
            var stored: [String: String] = [:]
            for row in rows {
                stored[row["key"] as String] = row["value"] as String
            }
            var out: [AppSettingKey: String] = [:]
            for key in AppSettingKey.allCases {
                out[key] = SettingsRules.resolved(stored[key.rawValue], key: key)
            }
            return out
        }
    }

    public func restoreDefaults() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM app_settings")
        }
    }

    /// 九开关等授权项（FR14.1 分目的授权）：布尔语义读取
    public func bool(for key: AppSettingKey) async throws -> Bool {
        try await value(for: key) == "true"
    }

    public struct AuditEntry: Sendable, Equatable {
        public var action: String
        public var entityType: String
        public var at: Date
        public init(action: String, entityType: String, at: Date) {
            self.action = action; self.entityType = entityType; self.at = at
        }
    }

    /// 审计列表（FR14.2）：append-only 事实，只读投影
    public func auditEntries(limit: Int = 100) async throws -> [AuditEntry] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT action, entity_type, at FROM audit_event ORDER BY at DESC LIMIT ?
                """, arguments: [limit]).map { row in
                AuditEntry(action: row["action"] as String,
                           entityType: row["entity_type"] as String,
                           at: Date(timeIntervalSince1970: row["at"] as Double))
            }
        }
    }
}
#endif
