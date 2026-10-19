import Foundation
import Domain
import Infrastructure
import Protocols
import Perception

/// 待办卡通知门面（结构轮 2026-09-15 自 CoreKit/Infrastructure/PendingCardStore.swift 移入 App）——
/// @MainActor @Perceptible 是**表现层状态**（@Environment 注入要求 @Observable，actor 不可直接注入），
/// 按 A1-F7 纪律归 App 层（与通知中心门面同族）；存储侧 PendingCardStore 保持 Infrastructure。
/// FR6.9 待办队列的可观察投影（非敏感摘要，BR-003：raw_text/partial_data 绝不外泄到视图）。
/// App 层环境注入门面（同 NotificationCenterState 纪律）：@Environment 要求
/// @Observable 类型，actor 不可直接注入——本门面把 FR6.9 待办队列暴露为
/// 可观察投影（ReminderAggregationCenter.pendingCardItem 非敏感摘要，
/// BR-003：raw_text/partial_data 绝不外泄到视图），供首页聚合中心消费。
@MainActor
@Perceptible
final class PendingCardCenterState {
    private(set) var items: [AggregatedReminderItem] = []
    /// 详情 sheet 用（D 级草稿详情仅用户本人可见；不进入任何事实链投影）
    private(set) var detail: PendingCard?
    private(set) var loadError: String?
    private let store: PendingCardStore
    /// 待办卡通知撤销/恢复（`pending-<id>` 已排程提醒）；测试/预览可 nil。
    private let scheduler: (any ReminderScheduling)?
    private var loadedPatientId: UUID?

    init(store: PendingCardStore, scheduler: (any ReminderScheduling)? = nil) {
        self.store = store
        self.scheduler = scheduler
    }

    func load(patientId: UUID) async {
        loadedPatientId = patientId
        loadError = nil
        // 收口批D 接线（第九轮审查 D3/FR6.9 §21.3）：生命周期推进此前**零调用**
        // （7 天过期/30 天归档、到期催办深链、PendingCardResumeRouteView 的
        // status 过滤全为不可达代码）。挂进本门面的装载链——每次待办投影装载
        // 顺带推进（幂等；失败容忍：推进失败不阻断列表装载，下一轮再试）。
        try? await store.advanceLifecycle()   // try?-ok: 推进失败不阻断装载（下轮幂等重试）
        do {
            let projected = try await store.aggregationItems(patientId: patientId)
            guard loadedPatientId == patientId else { return }   // BR-001 竞态守卫
            items = projected
        } catch {
            guard loadedPatientId == patientId else { return }
            loadError = String(describing: error)
            items = []   // try?-ok 同族：读取失败按空态渲染，不静默假数据
        }
    }

    func refresh(patientId: UUID) {
        Task { await load(patientId: patientId) }
    }

    /// 首页滑动删除（2026-10-19 业主指令）：源级软归档待办卡并刷新投影。
    /// 不删除草稿原文/医疗事实（BR-002），失败返回 false 由调用方保留行并提示。
    func discard(id: String, patientId: UUID) async -> Bool {
        do { try await store.archive(id: id, by: "user") } catch { return false }
        // 已排程的 `pending-<id>` 提醒必须同步撤销，否则删除后仍会弹通知
        // （同 DocumentsState.discardPendingCard 既有语义 §21.3）。撤销失败回滚归档。
        if let scheduler {
            do {
                try await scheduler.cancel(["pending-\(id)"])
                try await scheduler.removeDelivered(["pending-\(id)"])
            } catch {
                try? await store.restoreArchived(id: id)   // try?-ok: 回滚失败时下轮装载仍会按归档态处理，不影响投影正确性
                await load(patientId: patientId)
                return false
            }
        }
        await load(patientId: patientId)
        return true
    }

    /// 撤销首页删除：archived → pending、恢复 1h 待办提醒并刷新投影。
    func restore(id: String, patientId: UUID) async -> Bool {
        do { try await store.restoreArchived(id: id) } catch { return false }
        if let scheduler {
            try? await scheduler.schedule(dose: "pending-\(id)", at: Date().addingTimeInterval(3600), route: .pendingCard(id))   // try?-ok: 行已恢复，通知重排失败由下轮生命周期兜底
        }
        await load(patientId: patientId)
        return true
    }

    /// 用户补全完结（期一无 LLM 补全；resolved_by=user）后刷新投影。
}
