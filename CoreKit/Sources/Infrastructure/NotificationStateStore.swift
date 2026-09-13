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
import Perception

/// App 层环境注入外观（V3.72）：@Environment 要求 @Observable 类型，
/// actor 不可直接注入——本门面把已读/归档语义暴露为可观察状态并委托 actor。
///
/// round2 U3/U-N5/U-N6（FR14.8 / FR2.1⑦）三条纪律：
/// ① `load(keys:)` 只合并所请求的键（旧实现整体替换 `itemStates`，空键集
///    `states(for: []) → [:]` 直接清空——归档条目「复活」的根因之一）；
/// ② 写代次守卫：每次本地写 +1，加载以开始时的快照代次判定「加载期间是否
///    有更新写」，陈旧读不得回滚快照之后的本地写；
/// ③ 归档只剩**一种**语义——两阶段悲观（先落库，成功后再改可观察态）。
///    乐观 `markArchived(_:)`（先改态、后台 `try?` 落库）已删除：同一门面
///    两种归档语义，是首页与通知中心归档状态互相打架的根因（U-N5）。
@MainActor
@Perceptible
public final class NotificationCenterState {
    public private(set) var itemStates: [String: NotificationItemState] = [:]
    private let store: NotificationStateStore
    /// 写代次：每次本地写 +1；load 以快照代次判定「加载期间是否有更新写」（round2 U3/U-N6 竞态）。
    private var writeGeneration = 0
    private var lastWriteGeneration: [String: Int] = [:]

    public init(store: NotificationStateStore) { self.store = store }

    /// 加载开始时取快照代次（与 `applyLoaded(_:requestedKeys:snapshot:)` 配对；
    /// `load(keys:)` 内部即此二者合成，拆开暴露仅为可测竞态）。
    public func beginLoad() -> Int { writeGeneration }

    /// 只合并所请求键；快照后被本地写过的键不回滚。未登记键显式置 .unread（读侧 `?? .unread` 语义不变）。
    public func applyLoaded(_ loaded: [String: NotificationItemState], requestedKeys: [String], snapshot: Int) {
        for key in requestedKeys {
            if let g = lastWriteGeneration[key], g > snapshot { continue }
            itemStates[key] = loaded[key] ?? .unread
        }
    }

    public func load(keys: [String]) async {
        guard !keys.isEmpty else { return }    // 旧实现 states(for: []) → [:] 整体覆盖，归档复活根因之一
        let snapshot = beginLoad()
        let loaded: [String: NotificationItemState]
        do { loaded = try await store.states(for: keys) } catch { return }   // 读取失败保持现状：不清空、不假归档
        applyLoaded(loaded, requestedKeys: keys, snapshot: snapshot)
    }

    private func noteLocalWrite(_ key: String, _ state: NotificationItemState) {
        writeGeneration += 1; lastWriteGeneration[key] = writeGeneration; itemStates[key] = state
    }

    public func markRead(_ key: String) {
        noteLocalWrite(key, .read)
        Task { try? await store.markRead(key) }   // try?-ok: 已读为非破坏性标记，失败下次进入重试
    }

    /// 两阶段（首页写后动画）：先落库，成功后由视图在 withAnimation 内 applyArchived。
    public func persistArchive(_ key: String) async throws { try await store.markArchived(key) }
    public func persistUnarchive(_ key: String) async throws { try await store.unarchive(key) }
    public func applyArchived(_ key: String) { noteLocalWrite(key, .archived) }
    public func applyUnarchived(_ key: String) { noteLocalWrite(key, .read) }

    /// 唯一悲观归档路径（首页/通知中心共用；乐观 markArchived 删除——U-N5 同一门面两种语义）。
    /// 失败时条目继续可见（不静默假归档），调用方可决定重试。
    public func archive(_ key: String) async throws { try await persistArchive(key); applyArchived(key) }
    /// 撤销归档：落库成功后恢复为已读（归档前已有 read_at），条目重新可见。
    public func unarchive(_ key: String) async throws { try await persistUnarchive(key); applyUnarchived(key) }
}
#endif
