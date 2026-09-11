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
    /// 审查修复：再次稍后前先取消同剂量的旧 snooze——旧实现每次新排一个
    /// epoch 后缀 id，重复稍后叠加幽灵通知。
    /// 审查修复（返回成败）：旧实现吞错——调用侧先落 .snoozed 动作再调本
    /// 方法，调度失败时剂量已从待办消失且无任何后续触达（提醒静默丢失）。
    /// 返回 Bool 让调用侧「调度成功才记动作」。
    @discardableResult
    public func snooze(doseNotifyId: String, slotNotifyId: String?, until: Date) async -> Bool {
        // 审查修复（失败保持原状契约）：旧顺序先取消时段通知/旧 snooze 再排
        // 新通知——新排失败时旧通知已被取消、返回 false 却什么也没武装，
        // 与调用方「调度失败保持原状：原时段通知仍在」的注释矛盾。改先排
        // 新通知（失败即原样返回），成功后再撤销旧通知；撤销失败只记日志
        // 不翻盘（新提醒已武装，用户不会静默丢失提醒）。
        do {
            let snoozeId = "snooze-\(doseNotifyId)-\(Int(until.timeIntervalSince1970))"
            try await scheduler.schedule(dose: snoozeId, at: until, route: .reminderToday)
            if let slotId = slotNotifyId {
                do { try await scheduler.cancel([slotId]) }
                catch { logger?.log("snooze 时段通知取消失败: \(error)") }
            }
            let pending = try await scheduler.pending()
            let previous = pending.keys.filter { $0.hasPrefix("snooze-\(doseNotifyId)-") && $0 != snoozeId }
            if !previous.isEmpty {
                do { try await scheduler.cancel(Array(previous)) }
                catch { logger?.log("snooze 旧提醒取消失败: \(error)") }
            }
            return true
        } catch {
            logger?.log("snooze 调度失败: \(error)")
            return false
        }
    }

    /// 标识符优先级（dose-/slot-/snooze- 用药 > apt- 预约 > 其余随访/临期）。
    /// 第八轮全仓审查修复：slot-/snooze-（用药剂量时段与稍后提醒）此前落
    /// 入 tier 2（低于预约）——60 条预算裁剪时用药时段提醒先于预约被取消，
    /// 与「用药 > 预约」的声明层级矛盾。
    static func priorityOf(_ notifyId: String) -> Int {
        if notifyId.hasPrefix("dose-") || notifyId.hasPrefix("slot-") || notifyId.hasPrefix("snooze-") {
            return 0
        }
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
            let windowStart = DayArithmetic.offset(days: -1, from: now)
            let windowEnd = DayArithmetic.offset(days: ReconcileEngine.preScheduleWindowDays, from: now)
            let facts = try await source.deliveryFacts(from: windowStart, to: windowEnd)
            let delivered = try await scheduler.delivered()
            var pending = try await scheduler.pending()

            // FR9.17 通知半场（评审 P0）：时段级单条通知——未送达且未决剂量按时段
            // 聚合，每时段只发一条（展开内容由 UI 按 slot 查询实时组装）
            // 第七轮全仓审查修复：时段归属必须按**全量记录**分组反查——
            // 单剂派生 slotId 在合并时段（≤30min 双剂）对非锚剂量产生未排程的
            // 假 id：送达判定漏判 → 同一时段被重复调度第二条通知（FR9.17 破坏）、
            // 稍后取消错误 id。
            // 第八轮修复：锚剂量已决议、仅非锚剂量未决议时，按**未决议子集**
            // 分组会以非锚剂量重新锚定出第二个时段 id——送达判定再次漏判、
            // 重复调度。分组（id 来源）恒用全量记录；调度对象只保留含未决
            // 记录的时段（已全决时段不再触发通知）。
            let allRecords = facts.map { DoseRecord(dose: $0.dose) }
            let slotIdByDose = DoseSlotGrouping.slotIds(allRecords)
            let merged = facts.map { f -> DoseDeliveryFact in
                var m = f
                // 送达事实以系统 delivered 集为准（评审修正：DB 的 delivery_state
                // 只记迁移状态，decide 的 delivered 输入必须来自调度器）——
                // 剂量所属时段的通知送达即视为该剂量送达
                let slotNotifyId = slotIdByDose[f.dose.notifyId].map { "slot-\($0)" }
                m.delivered = f.delivered
                    || delivered.contains(f.dose.notifyId)
                    || (slotNotifyId.map { delivered.contains($0) } ?? false)
                return m
            }
            let undecided = merged.filter { $0.action == nil && !$0.delivered }
            let undecidedIds = Set(undecided.map(\.dose.notifyId))
            let slots = DoseSlotGrouping.group(allRecords).filter {
                $0.records.contains { undecidedIds.contains($0.id) }
            }

            for fact in merged {
                switch ReconcileEngine.decide(fact, now: now) {
                case .schedule:
                    break   // 时段级调度统一在下方处理
                case .markAwaitingUser:
                    try await source.markAwaitingUser(fact.dose.notifyId)
                case .snooze(let until):
                    if let slotId = slotIdByDose[fact.dose.notifyId].map({ "slot-\($0)" }) {
                        try await scheduler.cancel([slotId])
                    }
                    let snoozeId = "snooze-\(fact.dose.notifyId)-\(Int(until.timeIntervalSince1970))"
                    try await scheduler.schedule(dose: snoozeId, at: until, route: .reminderToday)
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
                    try await scheduler.schedule(dose: slotNotifyId, at: slot.anchorTime, route: .reminderToday)
                    pending[slotNotifyId] = slot.anchorTime
                }
            }

            // 到期自动停（FR9.15）：只清 dose-/slot- 前缀的残留 pending——
            // 评审修正 P0：旧实现把 apt- 预约提醒当「无事实来源」全删，预约闭环每次对账即断
            let activeSlotIds = Set(slots.map { "slot-\($0.id)" })
            // 审查修复：剂量已被确定动作（服/跳/忘/不适）解决的 snooze 幽灵通知
            // 也必须清——旧前缀过滤只清 dose-/slot-，稍后通知在确认后仍按时弹出
            let resolvedNotifyIds = Set(merged
                .filter { $0.action != nil && $0.action != .snoozed }
                .map { $0.dose.notifyId })
            let stale = pending.keys.filter { id in
                if id.hasPrefix("snooze-") {
                    let rest = String(id.dropFirst("snooze-".count))
                    let parts = rest.split(separator: "-")
                    guard let last = parts.last, Int(last) != nil else { return false }
                    let doseNotifyId = parts.dropLast().joined(separator: "-")
                    return resolvedNotifyIds.contains(doseNotifyId)
                }
                return (id.hasPrefix("dose-") || id.hasPrefix("slot-")) && !activeSlotIds.contains(id)
            }
            if !stale.isEmpty {
                try await scheduler.cancel(Array(stale))
            }
            // iOS 64 pending 上限（§5.4）：留 4 条余量，超限按优先级裁撤
            // （用药 > 预约 > 随访/临期；同优先级裁最晚触发者）。
            // 第八轮全仓审查修复（预算裁撤不得越权）：裁撤集只含对账自有
            // 命名空间（dose-/slot-/snooze-）——priorityOf 把 slot-/snooze-
            // 修正为用药档后，混合 pending 里 apt-（预约仓直排、对账不管理）
            // 反而先于用药被裁；旧 tier 2 又使 slot- 先于 apt- 被裁。两个
            // 方向都错：对账的预算阀只裁自己命名空间的通知，他仓（apt-/
            // followup-apt-/exp-/refill-/backup-/voice-rem-/alert-）由各自
            // 调度方负责。
            if pending.count > Self.pendingBudget {
                let owned = pending.filter { id, _ in
                    id.hasPrefix("dose-") || id.hasPrefix("slot-") || id.hasPrefix("snooze-")
                }
                // 预算阀按全局总量触发、但只裁自有命名空间——自有额度 =
                // 总预算 − 他仓占用：owned≤60 且总量>60 时旧逻辑什么都不裁，
                // 超 64 后由 iOS 按时间任意丢弃（可能含 dose-/slot-，用药
                // 优先保证失效）；owned 按自有额度裁撤才守住全局上限。
                let ownedBudget = max(0, Self.pendingBudget - (pending.count - owned.count))
                let entries = owned.map { (id: $0.key, fireAt: $0.value) }
                    .sorted {
                        if Self.priorityOf($0.id) != Self.priorityOf($1.id) { return Self.priorityOf($0.id) < Self.priorityOf($1.id) }
                        return $0.fireAt < $1.fireAt
                    }
                let drop = entries.dropFirst(ownedBudget).map(\.id)
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
