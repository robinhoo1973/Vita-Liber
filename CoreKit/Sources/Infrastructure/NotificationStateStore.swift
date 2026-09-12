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

    /// FR2.1 首页扫动处置（业主第10轮 §7）：撤销归档（Undo 条）；无记录时静默无操作。
    public func unarchive(_ key: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE notification_state SET archived_at = NULL WHERE item_key = ?",
                           arguments: [key])
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

#if os(iOS) || os(macOS)
import Observation

/// App 层环境注入外观（V3.72）：@Environment 要求 @Observable 类型，
/// actor 不可直接注入——本门面把已读/归档语义暴露为可观察状态并委托 actor。
@MainActor
@Observable
public final class NotificationCenterState {
    public private(set) var itemStates: [String: NotificationItemState] = [:]
    private let store: NotificationStateStore

    public init(store: NotificationStateStore) { self.store = store }

    public func load(keys: [String]) async {
        if let loaded = try? await store.states(for: keys) {   // try?-ok: 读取失败按未读渲染
            itemStates = loaded
        }
    }

    public func markRead(_ key: String) {
        itemStates[key] = .read
        Task {
            try? await store.markRead(key)   // try?-ok: 标记失败下次重试
        }
    }

    public func markArchived(_ key: String) {
        itemStates[key] = .archived
        Task {
            try? await store.markArchived(key)   // try?-ok: 归档失败本地态兜底
        }
    }

    /// 持久化归档（首页扫动处置用）：先落库成功才更新可观察状态——
    /// 失败时条目继续可见（不静默假归档），调用方可决定重试。
    public func archive(_ key: String) async throws {
        try await store.markArchived(key)
        itemStates[key] = .archived
    }

    /// 撤销归档：落库成功后恢复为已读（归档前已有 read_at），条目重新可见。
    public func unarchive(_ key: String) async throws {
        try await store.unarchive(key)
        itemStates[key] = .read
    }
}
#endif
