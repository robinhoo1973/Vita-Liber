import Foundation
import Testing
import Domain

/// SU-M2-DOSE-ADVISOR：FR9.19 服药时刻推荐（V4.04）。
/// 纯函数金样：推荐表、间隔通道、按需拒绝、隔日周期与均匀铺开边界。
@Suite("SU-M2-DOSE-ADVISOR FR9.19 服药时刻推荐")
struct DoseScheduleAdvisorTests {

    @Test("每日两次 → 08:00/20:00（≈12 小时间隔）")
    func bidRecommendsTwelveHourSpacing() {
        let proposal = DoseScheduleAdvisor.advise(timesPerDay: 2)
        #expect(proposal?.schedule == .fixed(times: ["08:00", "20:00"]))
        #expect(proposal?.basis == "bid")
    }

    @Test("每日三次 → 08:00/14:00/20:00；每日四次 → 08:00/12:00/16:00/20:00")
    func tidAndQidTables() {
        #expect(DoseScheduleAdvisor.advise(timesPerDay: 3)?.schedule == .fixed(times: ["08:00", "14:00", "20:00"]))
        #expect(DoseScheduleAdvisor.advise(timesPerDay: 4)?.schedule == .fixed(times: ["08:00", "12:00", "16:00", "20:00"]))
    }

    @Test("每日一次 → 08:00")
    func qdTable() {
        #expect(DoseScheduleAdvisor.advise(timesPerDay: 1)?.schedule == .fixed(times: ["08:00"]))
    }

    @Test("「每 N 小时」优先于次数表 → interval 提案自 08:00 起")
    func intervalHoursWinsOverTimesTable() {
        let proposal = DoseScheduleAdvisor.advise(timesPerDay: 2, intervalHours: 8)
        #expect(proposal?.schedule == .interval(everyMinutes: 480, start: "08:00"))
        #expect(proposal?.basis == "interval8h")
    }

    @Test("按需用药不推荐时刻（FR9.19 边界）")
    func asNeededYieldsNil() {
        #expect(DoseScheduleAdvisor.advise(timesPerDay: 2, isAsNeeded: true) == nil)
    }

    @Test("超出 1…4 次不猜 → nil")
    func outOfTableYieldsNil() {
        #expect(DoseScheduleAdvisor.advise(timesPerDay: 5) == nil)
        #expect(DoseScheduleAdvisor.advise(timesPerDay: 0) == nil)
        #expect(DoseScheduleAdvisor.advise(timesPerDay: nil) == nil)
    }

    @Test("隔日一次 → cycle(每 2 日 1 次)；非法 N → nil")
    func everyNDaysAdvisory() {
        #expect(DoseScheduleAdvisor.adviseEveryNDays(2)?.schedule == .cycle(everyDays: 2, daysOn: 1))
        #expect(DoseScheduleAdvisor.adviseEveryNDays(1) == nil)
    }

    @Test("均匀铺开：边界与步长")
    func evenlySpacedBoundaries() {
        #expect(DoseScheduleAdvisor.evenlySpacedTimes(count: 0) == [])
        #expect(DoseScheduleAdvisor.evenlySpacedTimes(count: 1) == ["08:00"])
        #expect(DoseScheduleAdvisor.evenlySpacedTimes(count: 5) == ["08:00", "11:00", "14:00", "17:00", "20:00"])
    }
}
