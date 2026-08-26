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

    /// 稍后提醒（S1-2 修正）：取消该剂量所属时段通知 + 按新时刻单排 snooze 通知。
    /// 调用方已写 user_action=.snoozed；本方法只做调度侧。
    public func snooze(doseNotifyId: String, slotNotifyId: String?, until: Date) async {
        do {
            if let slotId = slotNotifyId {
                try await scheduler.cancel([slotId])
            }
            let snoozeId = "snooze-\(doseNotifyId)-\(Int(until.timeIntervalSince1970))"
            try await scheduler.schedule(dose: snoozeId, at: until)
        } catch {
            logger?.log("snooze 调度失败: \(error)")
        }
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
            // 评审修正：窗口含前一天——过期剂量才能走 markAwaitingUser 分支
            let windowStart = now.addingTimeInterval(-86400)
            let windowEnd = now.addingTimeInterval(TimeInterval(ReconcileEngine.preScheduleWindowDays * 86400))
            let facts = try await source.deliveryFacts(from: windowStart, to: windowEnd)
            let delivered = try await scheduler.delivered()
            var pending = try await scheduler.pending()

            // FR9.17 通知半场（评审 P0）：时段级单条通知——未送达且未决剂量按时段
            // 聚合，每时段只发一条（展开内容由 UI 按 slot 查询实时组装）
            let merged = facts.map { f -> DoseDeliveryFact in
                var m = f
                // 送达事实以系统 delivered 集为准（评审修正：DB 的 delivery_state
                // 只记迁移状态，decide 的 delivered 输入必须来自调度器）——
                // 剂量所属时段的通知送达即视为该剂量送达
                let slotNotifyId = DoseSlotGrouping.slotId(for: DoseRecord(dose: f.dose)).map { "slot-\($0)" }
                m.delivered = f.delivered
                    || delivered.contains(f.dose.notifyId)
                    || (slotNotifyId.map { delivered.contains($0) } ?? false)
                return m
            }
            let undecided = merged.filter { $0.action == nil && !$0.delivered }
            let slots = DoseSlotGrouping.group(undecided.map { DoseRecord(dose: $0.dose) })

            for fact in merged {
                switch ReconcileEngine.decide(fact, now: now) {
                case .schedule:
                    break   // 时段级调度统一在下方处理
                case .markAwaitingUser:
                    try await source.markAwaitingUser(fact.dose.notifyId)
                case .snooze(let until):
                    if let slotId = DoseSlotGrouping.slotId(for: DoseRecord(dose: fact.dose)).map({ "slot-\($0)" }) {
                        try await scheduler.cancel([slotId])
                    }
                    let snoozeId = "snooze-\(fact.dose.notifyId)-\(Int(until.timeIntervalSince1970))"
                    try await scheduler.schedule(dose: snoozeId, at: until)
                    pending[snoozeId] = until
                case .none:
                    break
                }
            }

            for slot in slots {
                // 时段内仍有未送达且未决的剂量 → 时段级通知（未排才排）
                guard slot.records.contains(where: { _ in true }) else { continue }
                let slotNotifyId = "slot-\(slot.id)"
                if pending[slotNotifyId] == nil {
                    try await scheduler.schedule(dose: slotNotifyId, at: slot.anchorTime)
                    pending[slotNotifyId] = slot.anchorTime
                }
            }

            // 到期自动停（FR9.15）：只清 dose-/slot- 前缀的残留 pending——
            // 评审修正 P0：旧实现把 apt- 预约提醒当「无事实来源」全删，预约闭环每次对账即断
            let activeSlotIds = Set(slots.map { "slot-\($0.id)" })
            let stale = pending.keys.filter { id in
                (id.hasPrefix("dose-") || id.hasPrefix("slot-")) && !activeSlotIds.contains(id)
            }
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
