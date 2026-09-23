import Foundation
import Testing
import Domain

/// SU-M2-REFILL-PROJECTION：FR9.8.3 配药日历投影（V4.04 增补）。
/// 纯算术金样：向上取整（偏向更早）、提前量、耗尽边界与逾期标记。
@Suite("SU-M2-REFILL-PROJECTION FR9.8.3 配药日历投影")
struct RefillProjectionTests {

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        let calendar = makeCalendar()
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? Date()
    }

    @Test("6.4 天 → 向上取整 7 天：用尽日 = now+7，建议配药日 = 用尽日−3")
    func roundsUpAndSubtractsLeadTime() {
        let now = date(2026, 9, 24)
        let result = RefillProjection.project(relativeDays: 6.4, now: now, calendar: makeCalendar())
        #expect(result.depletionDate == date(2026, 10, 1))
        #expect(result.suggestedRefillDate == date(2026, 9, 28))
        #expect(result.suggestedRefillPassed == false)
    }

    @Test("整数天数不虚增（7.0 → now+7）")
    func integerDaysStable() {
        let now = date(2026, 9, 24)
        #expect(RefillProjection.project(relativeDays: 7.0, now: now, calendar: makeCalendar()).depletionDate
                == date(2026, 10, 1))
    }

    @Test("耗尽/负数 → 用尽日 = now（不虚构未来），建议配药日已过")
    func depletedClampsToNow() {
        let now = date(2026, 9, 24)
        let result = RefillProjection.project(relativeDays: -2, now: now, calendar: makeCalendar())
        #expect(result.depletionDate == now)
        #expect(result.suggestedRefillDate == date(2026, 9, 21))
        #expect(result.suggestedRefillPassed == true)
    }

    @Test("提前量为 0 → 建议配药日 = 用尽日")
    func zeroLeadTime() {
        let now = date(2026, 9, 24)
        let result = RefillProjection.project(relativeDays: 5, leadTimeDays: 0, now: now, calendar: makeCalendar())
        #expect(result.suggestedRefillDate == result.depletionDate)
    }
}
