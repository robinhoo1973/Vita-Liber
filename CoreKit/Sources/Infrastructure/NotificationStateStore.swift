#if os(iOS) || os(macOS)
import Foundation
import GRDB

/// FR14.8 / tech-spec §5.44 通知状态持久化（notification_state 表）：
/// 已读/归档标记的唯一写入口。此前该表随 DDL 入库但全仓零读写（死 DDL），
/// 通知中心的处理状态无任何持久化——重启即全部回到未读。
///
/// 六源聚合投影仍由视图层对各环境仓现算（各仓已按 BR-001 成员隔离），
/// 本仓只承载「处理状态」持久面；item_key 为通知条目稳定标识
/// （如 "dose-<id>" / "apt-<id>" / "alert-<id>"）。
public enum NotificationItemState: String, Sendable, Equatable {
    case unread, read, archived
}

public actor NotificationStateStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public func markRead(_ key: String) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO notification_state (item_key, kind, read_at)
                VALUES (?, 'notification', ?)
                ON CONFLICT(item_key) DO UPDATE SET read_at = excluded.read_at
                """, arguments: [key, Date().timeIntervalSince1970])
        }
    }

    public func markArchived(_ key: String) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO notification_state (item_key, kind, read_at, archived_at)
                VALUES (?, 'notification', ?, ?)
                ON CONFLICT(item_key) DO UPDATE SET archived_at = excluded.archived_at
                """, arguments: [key, Date().timeIntervalSince1970, Date().timeIntervalSince1970])
        }
    }

    /// 批量读取处理状态（键集合 → 状态；未登记键 = .unread）
    public func states(for keys: [String]) async throws -> [String: NotificationItemState] {
        guard !keys.isEmpty else { return [:] }
        return try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT item_key, read_at, archived_at FROM notification_state
                WHERE item_key IN (\(keys.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(keys))
            var out: [String: NotificationItemState] = [:]
            for row in rows {
                let key: String = row["item_key"]
                if (row["archived_at"] as Double?) != nil {
                    out[key] = .archived
                } else if (row["read_at"] as Double?) != nil {
                    out[key] = .read
                } else {
                    out[key] = .unread
                }
            }
            return out
        }
    }
}
#endif
