import Foundation
import Domain
import Protocols

/// §5.4 对账引擎（V3.29 四层补偿共用同一入口；actor 内去重防并发重复对账）。
/// 平台无关：只依赖 ReminderScheduling/DoseSource 协议——Linux 可全量单测。
public actor ReminderReconciler {
    private let scheduler: any ReminderScheduling
    private let source: any DoseSource
    private var isReconciling = false
    private let logger: ReconcilerLogging?

    public init(scheduler: any ReminderScheduling, source: any DoseSource,
                logger: ReconcilerLogging? = nil) {
        self.scheduler = scheduler
        self.source = source
        self.logger = logger
    }

    /// 四层触发（启动/回前台/时区变更/BGTask）都调这里；任一层成功即满足正确性
    public func reconcile(now: Date) async {
        guard !isReconciling else { return }   // 多层同时触发去重
        isReconciling = true
        defer { isReconciling = false }
        do {
            let windowEnd = now.addingTimeInterval(TimeInterval(ReconcileEngine.preScheduleWindowDays * 86400))
            let facts = try await source.deliveryFacts(from: now, to: windowEnd)
            let delivered = try await scheduler.delivered()
            var pending = try await scheduler.pending()

            for f in facts {
                switch ReconcileEngine.decide(f, now: now) {
                case .schedule:
                    if pending[f.dose.notifyId] == nil {
                        try await scheduler.schedule(dose: f.dose.notifyId, at: f.dose.dueAt)
                        pending[f.dose.notifyId] = f.dose.dueAt
                    }
                case .markAwaitingUser:
                    try await source.markAwaitingUser(f.dose.notifyId)
                case .snooze(let until):
                    try await scheduler.cancel([f.dose.notifyId])
                    try await scheduler.schedule(dose: f.dose.notifyId, at: until)
                    pending[f.dose.notifyId] = until
                case .none:
                    break
                }
            }
            // 到期自动停（FR9.15）：计划 ended/endDate 次日 → 批量移除该计划全部 pending
            // （deliveryFacts 不再返回 ended 计划的剂量；此处在 pending 中清除无事实来源的过期项）
            let activeIds = Set(facts.map(\.dose.notifyId))
            let stale = pending.keys.filter { !activeIds.contains($0) }
            if !stale.isEmpty {
                try await scheduler.cancel(Array(stale))
            }
        } catch {
            logger?.log("reconcile 失败: \(error)")
        }
    }
}

/// 日志端口（App 层注入 os.Logger 适配；CoreKit 保持平台无关）
public protocol ReconcilerLogging: Sendable {
    func log(_ message: String)
}

public struct PrintLogger: ReconcilerLogging {
    public init() {}
    public func log(_ message: String) { print("[ReminderReconciler] \(message)") }
}
