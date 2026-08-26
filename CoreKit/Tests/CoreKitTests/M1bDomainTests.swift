import Foundation
import Testing
@testable import Domain

/// M1b 核心数据与提醒 · Domain 层验收用例（dev-pm §3.2.2 退出准则的 U 半场）
@Suite("M1b · 调度引擎（§5.4 schedule_json）")
struct ScheduleEngineTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }
    private var start: Date {
        cal.date(from: DateComponents(year: 2026, month: 8, day: 26))!
    }

    @Test func 固定时间双剂() {
        let (doses, skipped) = DoseScheduleEngine.doses(
            schedule: .fixed(times: ["08:00", "20:00"]),
            planId: UUID(), startDate: start, fromDay: 1, toDay: 1, calendar: cal)
        #expect(doses.count == 2 && skipped == 0)
        #expect(doses[0].dueAt < doses[1].dueAt)
        #expect(doses.allSatisfy { $0.notifyId.hasPrefix("dose-") })
    }

    @Test func 间隔每480分钟生成3剂() {
        let (doses, _) = DoseScheduleEngine.doses(
            schedule: .interval(everyMinutes: 480, start: "08:00"),
            planId: UUID(), startDate: start, fromDay: 1, toDay: 1, calendar: cal)
        #expect(doses.count == 3)   // 08:00 / 16:00 / 24:00 边界不含
    }

    @Test func 按需不预排() {
        let (doses, _) = DoseScheduleEngine.doses(
            schedule: .asNeeded, planId: UUID(), startDate: start, fromDay: 1, toDay: 7, calendar: cal)
        #expect(doses.isEmpty)
    }

    @Test func 递增递减表阶段剂量() {
        let stages = [
            MedicationSchedule.TaperStage(phase: 1, fromDay: 1, toDay: 7, doseUnits: 2.0, times: ["08:00"]),
            MedicationSchedule.TaperStage(phase: 2, fromDay: 8, toDay: 14, doseUnits: 1.0, times: ["08:00"]),
        ]
        let (doses, _) = DoseScheduleEngine.doses(
            schedule: .taper(stages: stages), planId: UUID(),
            startDate: start, fromDay: 1, toDay: 14, calendar: cal)
        #expect(doses.count == 14)
        #expect(doses[0].doseUnits == 2.0 && doses[7].doseUnits == 1.0)
    }

    @Test func 非法时间字符串跳过并计数() {
        let (doses, skipped) = DoseScheduleEngine.doses(
            schedule: .fixed(times: ["25:00", "08:00"]),
            planId: UUID(), startDate: start, fromDay: 1, toDay: 1, calendar: cal)
        #expect(doses.count == 1 && skipped == 1)   // 绝不静默错位
    }

    @Test func 计划状态闸门() {
        #expect(ScheduleGate.dosesAllowed(.active))
        #expect(!ScheduleGate.dosesAllowed(.paused))
        #expect(!ScheduleGate.dosesAllowed(.ended))
    }
}

@Suite("M1b · 双轨库存扣减矩阵（FR9.8/9.8.2，ADR-009）")
struct DualTrackTests {
    @Test func 安全线与确认线独立扣减() {
        var inv = DualTrackInventory(lotId: UUID(), totalUnits: 30, unitKind: "tablet")
        inv = InventoryRules.deductPlan(inv, units: 2)        // 调度发出 → 安全线扣
        #expect(inv.remainingPlanUnits == 28)
        #expect(inv.remainingConfirmedUnits == 30)            // 确认线不动（BR-004）
        inv = InventoryRules.deductConfirmed(inv, units: 1)   // 用户「服了」→ 确认线扣
        #expect(inv.remainingConfirmedUnits == 29)
    }

    @Test func 跳过与忘记零扣减() {
        // 跳过/忘记/不适只写动作，双线都不扣（纯事实）
        var inv = DualTrackInventory(lotId: UUID(), totalUnits: 30, unitKind: "tablet")
        inv = InventoryRules.deductPlan(inv, units: 1)
        #expect(inv.remainingPlanUnits == 29 && inv.remainingConfirmedUnits == 30)
    }

    @Test func FEFO先到期先出() {
        let early = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet",
                                       expireAt: Date(timeIntervalSince1970: 1000))
        let late = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet",
                                      expireAt: Date(timeIntervalSince1970: 2000))
        #expect(InventoryRules.fefoOrder([late, early])[0].lotId == early.lotId)
    }

    @Test func 扣减矩阵跨批FEFO分配() {
        let early = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet",
                                       expireAt: Date(timeIntervalSince1970: 1000))
        let late = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet",
                                      expireAt: Date(timeIntervalSince1970: 2000))
        let (updated, allocs) = InventoryRules.allocateConfirmed(lots: [late, early], units: 15)
        #expect(allocs.count == 2)
        #expect(allocs[0].lotId == early.lotId && allocs[0].units == 10)   // 先到期全扣
        #expect(allocs[1].lotId == late.lotId && allocs[1].units == 5)
        #expect(updated.first { $0.lotId == early.lotId }!.remainingConfirmedUnits == 0)
    }

    @Test func 续药告警七天余量() {
        let inv = DualTrackInventory(lotId: UUID(), totalUnits: 21, unitKind: "tablet")
        let withPlan = InventoryRules.deductPlan(inv, units: 0)
        #expect(InventoryRules.refillAlertNeeded(withPlan, dailyPlanUnits: 3, at: Date()))
        let plenty = DualTrackInventory(lotId: UUID(), totalUnits: 100, unitKind: "tablet")
        #expect(!InventoryRules.refillAlertNeeded(plenty, dailyPlanUnits: 3, at: Date()))
    }
}

@Suite("M1b · 时段聚合（FR9.17）")
struct DoseSlotTests {
    /// 测试日历：固定时区，锚点 = 当日 startOfDay + 餐时默认时刻
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }
    private var mealAnchor: Date {
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        return start.addingTimeInterval((8 * 60 + 30) * 60)   // afterBreakfast 默认 08:30
    }

    private func dose(_ offset: TimeInterval, meal: String?) -> ScheduledDose {
        ScheduledDose(dueAt: mealAnchor.addingTimeInterval(offset), doseUnits: 1,
                      mealRelation: meal, notifyId: "dose-\(offset)-\(meal ?? "f")")
    }

    @Test func 餐时关系正负三十分钟归组() {
        let records = [
            DoseRecord(dose: dose(0, meal: "afterBreakfast")),
            DoseRecord(dose: dose(15 * 60, meal: "afterBreakfast")),
            DoseRecord(dose: dose(-20 * 60, meal: "afterBreakfast")),
            DoseRecord(dose: dose(40 * 60, meal: "afterBreakfast")),   // 超容差 → 新时段
        ]
        let slots = DoseSlotGrouping.group(records, calendar: cal)
        #expect(slots.count == 2)
        #expect(slots[0].records.count == 3 && slots[1].records.count == 1)
    }

    @Test func 不同餐时关系不混组() {
        let records = [
            DoseRecord(dose: dose(0, meal: "afterBreakfast")),
            DoseRecord(dose: dose(5 * 60, meal: "afterDinner")),
        ]
        #expect(DoseSlotGrouping.group(records, calendar: cal).count == 2)
    }

    @Test func 全部已服判定() {
        let d1 = dose(0, meal: "afterBreakfast")
        let d2 = dose(10 * 60, meal: "afterBreakfast")
        let slot = DoseSlotGrouping.group([
            DoseRecord(dose: d1, action: .taken),
            DoseRecord(dose: d2, action: .taken),
        ], calendar: cal)[0]
        #expect(slot.allTaken && !slot.anyPending)
        let partial = DoseSlotGrouping.group([
            DoseRecord(dose: d1, action: .taken),
            DoseRecord(dose: d2, action: nil),
        ], calendar: cal)[0]
        #expect(!partial.allTaken && partial.anyPending)
    }

    @Test func 无餐时关系传递聚类() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func fixed(_ offset: TimeInterval) -> DoseRecord {
            DoseRecord(dose: ScheduledDose(dueAt: base.addingTimeInterval(offset), doseUnits: 1,
                                           mealRelation: nil, notifyId: "f-\(offset)"))
        }
        // -20/0/+15 传递相连（两两 ≤30min）→ 一段；+50 断链 → 第二段
        let slots = DoseSlotGrouping.group([fixed(0), fixed(15 * 60), fixed(-20 * 60), fixed(50 * 60)], calendar: cal)
        #expect(slots.count == 2)
        #expect(slots[0].records.count == 3 && slots[1].records.count == 1)
    }
}

@Suite("M1b · 对账决策与通道降级（§5.4/FR9.18）")
struct ReconcileTests {
    private func fact(delivered: Bool, action: DoseUserAction?, dueSoon: Bool, grace: Bool) -> DoseDeliveryFact {
        DoseDeliveryFact(dose: ScheduledDose(dueAt: Date(), doseUnits: 1, notifyId: "d-1"),
                         delivered: delivered, action: action, isDueSoon: dueSoon, isExpiredGrace: grace)
    }

    @Test func 已服不动() {
        #expect(ReconcileEngine.decide(fact(delivered: true, action: .taken, dueSoon: false, grace: false), now: Date()) == .none)
    }

    @Test func 未送达且临期补排() {
        #expect(ReconcileEngine.decide(fact(delivered: false, action: nil, dueSoon: true, grace: false), now: Date()) == .schedule)
    }

    @Test func 已送达过宽限期标记待处理() {
        #expect(ReconcileEngine.decide(fact(delivered: true, action: nil, dueSoon: false, grace: true), now: Date()) == .markAwaitingUser)
    }

    @Test func 稍后提醒必须晚于现在() {
        let past = Date().addingTimeInterval(-60)
        #expect(ReconcileEngine.snooze(until: past, now: Date()) == .none)
        let future = Date().addingTimeInterval(600)
        #expect(ReconcileEngine.snooze(until: future, now: Date()) == .snooze(until: future))
    }

    @Test func 超限裁撤按优先级() {
        let pending = [
            (id: "med-1", priority: ReconcileEngine.Priority.medication, fireAt: Date()),
            (id: "follow-1", priority: ReconcileEngine.Priority.followUp, fireAt: Date()),
            (id: "apt-1", priority: ReconcileEngine.Priority.appointment, fireAt: Date()),
        ]
        let dropped = ReconcileEngine.trim(pending, budget: 2)
        #expect(dropped == ["follow-1"])   // 裁撤顺序：观察随访优先让位
    }

    @Test func 通道降级矩阵() {
        let chain = ChannelFallback.resolve(
            preferred: .local,
            availability: [.local: false, .inApp: true, .persistentRing: true])
        #expect(chain == .inApp)
        let fallbackToRing = ChannelFallback.resolve(
            preferred: .local,
            availability: [.local: false, .inApp: false, .persistentRing: true])
        #expect(fallbackToRing == .persistentRing)
        let none = ChannelFallback.resolve(
            preferred: .serverPush,
            availability: [.local: false, .inApp: false, .persistentRing: false])
        #expect(none == nil)
    }

    @Test func 预约四级触发点反算() {
        let startsAt = Date(timeIntervalSince1970: 1_800_000_000)
        let now = startsAt.addingTimeInterval(-30 * 86400)
        let dates = AppointmentRules.tierFireDates(startsAt: startsAt, tiers: AppointmentTier.defaults, now: now)
        #expect(dates.count == 4)
        // 已过期层级不补发
        let lateNow = startsAt.addingTimeInterval(-1 * 3600)
        let datesLate = AppointmentRules.tierFireDates(startsAt: startsAt, tiers: AppointmentTier.defaults, now: lateNow)
        #expect(datesLate.isEmpty)   // 全部层级已过期
    }
}
