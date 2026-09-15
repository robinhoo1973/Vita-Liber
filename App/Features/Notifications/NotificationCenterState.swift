import Foundation
import Domain
import Infrastructure
import Perception

/// 通知中心可观察门面（结构轮 2026-09-15 自 CoreKit/Infrastructure/NotificationStateStore.swift 移入 App）——
/// @MainActor @Perceptible 是表现层状态（@Environment 注入要求 @Observable，actor 不可直接注入），
/// 按 A1-F7 纪律归 App 层；存储侧 NotificationStateStore（actor）保持 Infrastructure。
/// 本族搬移完成后 CoreKit 不再依赖 Perception/IssueReporting（分层复位，下一提交摘除包依赖）。
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
final class NotificationCenterState {
    private(set) var itemStates: [String: NotificationItemState] = [:]
    private let store: NotificationStateStore
    /// 写代次：每次本地写 +1；load 以快照代次判定「加载期间是否有更新写」（round2 U3/U-N6 竞态）。
    private var writeGeneration = 0
    private var lastWriteGeneration: [String: Int] = [:]

    init(store: NotificationStateStore) { self.store = store }

    /// 加载开始时取快照代次（与 `applyLoaded(_:requestedKeys:snapshot:)` 配对；
    /// `load(keys:)` 内部即此二者合成，拆开暴露仅为可测竞态）。
    func beginLoad() -> Int { writeGeneration }

    /// 只合并所请求键；快照后被本地写过的键不回滚。未登记键显式置 .unread（读侧 `?? .unread` 语义不变）。
    func applyLoaded(_ loaded: [String: NotificationItemState], requestedKeys: [String], snapshot: Int) {
        for key in requestedKeys {
            if let g = lastWriteGeneration[key], g > snapshot { continue }
            itemStates[key] = loaded[key] ?? .unread
        }
    }

    func load(keys: [String]) async {
        guard !keys.isEmpty else { return }    // 旧实现 states(for: []) → [:] 整体覆盖，归档复活根因之一
        let snapshot = beginLoad()
        let loaded: [String: NotificationItemState]
        do { loaded = try await store.states(for: keys) } catch { return }   // 读取失败保持现状：不清空、不假归档
        applyLoaded(loaded, requestedKeys: keys, snapshot: snapshot)
    }

    private func noteLocalWrite(_ key: String, _ state: NotificationItemState) {
        writeGeneration += 1; lastWriteGeneration[key] = writeGeneration; itemStates[key] = state
    }

    func markRead(_ key: String) {
        noteLocalWrite(key, .read)
        Task { try? await store.markRead(key) }   // try?-ok: 已读为非破坏性标记，失败下次进入重试
    }

    /// 两阶段（首页写后动画）：先落库，成功后由视图在 withAnimation 内 applyArchived。
    func persistArchive(_ key: String) async throws { try await store.markArchived(key) }
    func persistUnarchive(_ key: String) async throws { try await store.unarchive(key) }
    func applyArchived(_ key: String) { noteLocalWrite(key, .archived) }
    func applyUnarchived(_ key: String) { noteLocalWrite(key, .read) }

    /// 唯一悲观归档路径（首页/通知中心共用；乐观 markArchived 删除——U-N5 同一门面两种语义）。
    /// 失败时条目继续可见（不静默假归档），调用方可决定重试。
    func archive(_ key: String) async throws { try await persistArchive(key); applyArchived(key) }
    /// 撤销归档：落库成功后恢复为已读（归档前已有 read_at），条目重新可见。
    func unarchive(_ key: String) async throws { try await persistUnarchive(key); applyUnarchived(key) }
}
