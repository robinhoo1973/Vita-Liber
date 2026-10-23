import Foundation
import Testing
@testable import Domain

// binds: FR11.4 健康史年份校验与病程年数（2026-10-23）
@Suite("HealthProblemRules 年份与病程")
struct HealthProblemRulesTests {
    /// 固定「今年」= 2026，避免测试随真实时钟跨年漂移。
    private var now: Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 23))!
    }
    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    @Test("合法年份解析")
    func parseValid() {
        #expect(HealthProblemRules.parseYear("2020", now: now, calendar: calendar) == 2020)
        #expect(HealthProblemRules.parseYear(" 1998 ", now: now, calendar: calendar) == 1998)
        #expect(HealthProblemRules.parseYear("1900", now: now, calendar: calendar) == 1900)
        #expect(HealthProblemRules.parseYear("2026", now: now, calendar: calendar) == 2026)
    }

    @Test("非法/未来年份拒绝")
    func parseInvalid() {
        #expect(HealthProblemRules.parseYear("", now: now, calendar: calendar) == nil)
        #expect(HealthProblemRules.parseYear("202", now: now, calendar: calendar) == nil)
        #expect(HealthProblemRules.parseYear("24", now: now, calendar: calendar) == nil)
        #expect(HealthProblemRules.parseYear("abcd", now: now, calendar: calendar) == nil)
        #expect(HealthProblemRules.parseYear("1899", now: now, calendar: calendar) == nil)
        #expect(HealthProblemRules.parseYear("2027", now: now, calendar: calendar) == nil)
    }

    @Test("病程年数：今年为 0，旧年份为差值")
    func duration() {
        #expect(HealthProblemRules.durationYears(since: 2026, now: now, calendar: calendar) == 0)
        #expect(HealthProblemRules.durationYears(since: 2020, now: now, calendar: calendar) == 6)
        #expect(HealthProblemRules.durationYears(since: 1998, now: now, calendar: calendar) == 28)
    }

    @Test("病程年数：未知/非法/未来为 nil")
    func durationInvalid() {
        #expect(HealthProblemRules.durationYears(since: nil, now: now, calendar: calendar) == nil)
        #expect(HealthProblemRules.durationYears(since: 1899, now: now, calendar: calendar) == nil)
        #expect(HealthProblemRules.durationYears(since: 2027, now: now, calendar: calendar) == nil)
    }

    /// 2026-10-23 业主：年份改滚轮——滚轮范围必须与保存层解析同一事实源，
    /// 否则滚轮会提供「选了却存不进去」的年份。
    @Test("滚轮年份范围 = 1900…今年，且每项都能被 parseYear 接受")
    func yearRangeMatchesParser() {
        let range = HealthProblemRules.yearRange(now: now, calendar: calendar)
        #expect(range == 1900...2026)
        #expect(range.allSatisfy {
            HealthProblemRules.parseYear(String($0), now: now, calendar: calendar) == $0
        })
        #expect(!range.contains(2027))
        #expect(!range.contains(1899))
    }
}
