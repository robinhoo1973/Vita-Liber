import Foundation
import Testing
@testable import Domain

// binds: FR9.19 常用提醒范围与时段身份（v43，2026-10-23 业主）
@Suite("MedicationScheduleEntryRules 范围与条目")
struct MedicationScheduleEntryTests {
    @Test("默认范围半开且包含自身提醒时刻，相邻时段不重叠")
    func defaultRangesContainDefaultTimeAndDoNotOverlap() {
        for slot in DoseTimeSlot.allCases {
            let range = MedicationScheduleEntryRules.defaultRange(for: slot)
            #expect(MedicationScheduleEntryRules.contains(slot.defaultTime, in: range))
        }
        // 起床后 [07:00,07:30) 与 早餐前 [07:30,08:00) 在 07:30 处不重叠
        let wake = MedicationScheduleEntryRules.defaultRange(for: .afterWake)
        let breakfast = MedicationScheduleEntryRules.defaultRange(for: .beforeBreakfast)
        #expect(wake.end == breakfast.start)
        #expect(!MedicationScheduleEntryRules.contains("07:30", in: wake))
        #expect(MedicationScheduleEntryRules.contains("07:30", in: breakfast))
    }

    @Test("旧时刻数组：默认值认领时段，其余保持自定义")
    func legacyTimesMapToEntries() {
        let entries = MedicationScheduleEntryRules.entries(
            fromLegacyTimes: ["07:30", "07:45", "19:30"])
        #expect(entries.count == 3)
        #expect(entries[0].slot == .beforeBreakfast)
        #expect(entries[1].slot == nil)
        #expect(entries[2].slot == .afterDinner)
    }

    @Test("校验：空/非法时刻/重复分钟/同时段/非法范围")
    func validation() {
        #expect(MedicationScheduleEntryRules.validate([]) == .empty)
        #expect(MedicationScheduleEntryRules.validate(
            [.init(slot: nil, time: "25:99")]) == .invalidTime)
        #expect(MedicationScheduleEntryRules.validate(
            [.init(slot: nil, time: "08:00"), .init(slot: nil, time: "8:00")]) == .duplicateTime)
        #expect(MedicationScheduleEntryRules.validate(
            [.init(slot: .afterWake, time: "07:00"),
             .init(slot: .afterWake, time: "07:10")]) == .duplicateSlot)
        #expect(MedicationScheduleEntryRules.validate(
            [.init(slot: nil, time: "08:00", rangeStart: "09:00", rangeEnd: "08:00")])
            == .invalidRange)
        #expect(MedicationScheduleEntryRules.validate(
            [.init(slot: nil, time: "08:00", rangeStart: "08:00")]) == .invalidRange)
        #expect(MedicationScheduleEntryRules.validate(
            [.init(slot: .beforeBreakfast, time: "07:30")]) == nil)
    }

    @Test("时刻越出范围只产生软提示，不是校验错误")
    func outsideRangeIsNoticeOnly() {
        let entries = [MedicationScheduleEntry(
            slot: .beforeBreakfast, time: "09:00",
            rangeStart: "07:30", rangeEnd: "08:00")]
        #expect(MedicationScheduleEntryRules.validate(entries) == nil)
        #expect(MedicationScheduleEntryRules.timesOutsideRange(entries).count == 1)
    }

    @Test("规范化：补默认范围、按分钟排序、去重")
    func normalizeFillsRangesAndSorts() {
        let entries = MedicationScheduleEntryRules.normalize([
            .init(slot: .afterDinner, time: "19:30"),
            .init(slot: .beforeBreakfast, time: "07:30"),
            .init(slot: nil, time: "19:30"),
        ])
        #expect(entries.map(\.time) == ["07:30", "19:30"])
        #expect(entries[0].rangeStart == "07:30")
        #expect(entries[0].rangeEnd == "08:00")
        #expect(entries[1].rangeStart == "19:30")
        #expect(entries[1].rangeEnd == "20:00")
        #expect(MedicationScheduleEntryRules.times(entries) == ["07:30", "19:30"])
    }
}
