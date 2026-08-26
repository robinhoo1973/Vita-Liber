import Foundation
import Domain
import Protocols

/// §5.4 对账引擎（V3.29 四层补偿共用同一入口；actor 内去重防并发重复对账）。
/// 平台无关：只依赖 ReminderScheduling/DoseSource 协议——Linux 可全量单测。
public actor ReminderReconciler {
    /// 预算 = 64 - 4 余量（§5.4：系统静默丢弃超限 pending，留余量给即时预警）
    public static let pendingBudget = 60

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

    /// 标识符优先级（dose- 用药 > apt- 预约 > 其余随访/临期）
    static func priorityOf(_ notifyId: String) -> Int {
        if notifyId.hasPrefix("dose-") { return 0 }
        if notifyId.hasPrefix("apt-") { return 1 }
        return 2
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
            // iOS 64 pending 上限（§5.4）：留 4 条余量，超限按优先级裁撤
            // （用药 > 预约 > 随访/临期；同优先级裁最晚触发者）
            if pending.count > Self.pendingBudget {
                let entries = pending.map { (id: $0.key, fireAt: $0.value) }
                    .sorted {
                        if Self.priorityOf($0.id) != Self.priorityOf($1.id) { return Self.priorityOf($0.id) < Self.priorityOf($1.id) }
                        return $0.fireAt < $1.fireAt
                    }
                let drop = entries.dropFirst(Self.pendingBudget).map(\.id)
                try await scheduler.cancel(drop)
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
