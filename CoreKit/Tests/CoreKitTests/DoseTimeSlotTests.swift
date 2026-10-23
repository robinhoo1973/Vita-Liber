import Foundation
import Testing
@testable import Domain

/// FR9.4 服药时段（2026-10-23 业主指令）：默认时刻与餐锚同源、覆盖/去重/排序、
/// DatePicker 字符串互转。纯函数金样，Linux 可跑。
// binds: SU-M1b-DOSE-SLOT
@Suite("SU-M1b-DOSE-SLOT FR9.4 服药时段")
struct DoseTimeSlotTests {

    @Test("餐锚时段默认时刻与引擎 mealDefaultTime 同源")
    func mealSlotsShareEngineDefaults() {
        for slot in DoseTimeSlot.allCases {
            guard let relation = slot.mealRelation else { continue }
            #expect(slot.defaultTime == DoseScheduleEngine.mealDefaultTime(relation))
        }
        #expect(DoseTimeSlot.afterWake.defaultTime == "07:00")
    }

    @Test("起床后不是餐锚——不猜空腹/餐后语义")
    func afterWakeHasNoMealRelation() {
        #expect(DoseTimeSlot.afterWake.mealRelation == nil)
        #expect(DoseTimeSlot.beforeBreakfast.mealRelation == "beforeBreakfast")
        #expect(DoseTimeSlot.beforeSleep.mealRelation == "beforeSleep")
    }

    @Test("覆盖时刻优先于默认时刻，并按分钟升序")
    func overridesWinAndSort() {
        let times = DoseTimeSlotRules.times([.beforeBreakfast, .afterDinner, .afterWake],
                                            overrides: [.beforeBreakfast: "09:15"])
        #expect(times == ["07:00", "09:15", "19:30"])
    }

    @Test("同一时刻去重，非法时刻丢弃")
    func dedupeAndDropInvalid() {
        let times = DoseTimeSlotRules.times([.afterWake, .beforeBreakfast],
                                            overrides: [.beforeBreakfast: "07:00"])
        #expect(times == ["07:00"])

        let invalid = DoseTimeSlotRules.times([.beforeLunch],
                                              overrides: [.beforeLunch: "25:99"])
        #expect(invalid.isEmpty)
    }

    @Test("同一分钟的不同写法视为同一时刻（08:30 与 8:30）")
    func dedupeUsesMinutesNotRawStrings() {
        let times = DoseTimeSlotRules.times([.beforeBreakfast, .beforeLunch],
                                            overrides: [.beforeBreakfast: "8:30",
                                                        .beforeLunch: "08:30"])
        #expect(times.count == 1)
        #expect(DoseTimeSlotRules.minutes(times[0]) == 8 * 60 + 30)
    }

    @Test("DatePicker 互转：合法时刻往返、非法时刻不猜")
    func dateRoundTrip() throws {
        let calendar = Calendar(identifier: .gregorian)
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let date = try #require(DoseTimeSlotRules.date(for: "07:30", on: day, calendar: calendar))
        #expect(DoseTimeSlotRules.timeString(from: date, calendar: calendar) == "07:30")
        #expect(DoseTimeSlotRules.date(for: "7点半", on: day, calendar: calendar) == nil)
    }
}
