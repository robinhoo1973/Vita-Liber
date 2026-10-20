import Testing
import Foundation
@testable import Domain

/// 业主 2026-10-20：导入范围 + 初始完成态。纯 Domain 测试（Linux 可跑）。
struct HealthImportPlanTests {

    private func plan(_ depth: HealthHistoryDepth,
                      completions: [String: HealthKindCompletion] = [:]) -> HealthImportPlan {
        HealthImportPlan(depth: depth, selectedAt: Date(timeIntervalSince1970: 1_700_000_000),
                         completions: completions)
    }

    @Test func oneYearCoverageRequiresRecentOnlyAtOneYear() {
        var completions: [String: HealthKindCompletion] = [:]
        for kind in HealthDataKind.allCases {
            completions[kind.rawValue] = HealthKindCompletion(
                recentCompletedAt: Date(), historyCompletedAt: Date(), historyDepth: .oneYear)
        }
        let p = plan(.oneYear, completions: completions)
        #expect(p.remainingKinds(depth: .oneYear).isEmpty)
        #expect(!p.remainingKinds(depth: .fiveYears).isEmpty)
        #expect(!p.remainingKinds(depth: .all).isEmpty)
    }

    @Test func allHistoryCoverageCoversNarrowerDepthsButNotViceVersa() {
        var completions: [String: HealthKindCompletion] = [:]
        for kind in HealthDataKind.allCases {
            completions[kind.rawValue] = HealthKindCompletion(
                recentCompletedAt: Date(), historyCompletedAt: Date(), historyDepth: .all)
        }
        let all = plan(.all, completions: completions)
        #expect(all.covers(.heartRate, depth: .oneYear))
        #expect(all.covers(.heartRate, depth: .fiveYears))
        #expect(all.covers(.heartRate, depth: .all))

        var five: [String: HealthKindCompletion] = [:]
        for kind in HealthDataKind.allCases {
            five[kind.rawValue] = HealthKindCompletion(
                recentCompletedAt: Date(), historyCompletedAt: Date(), historyDepth: .fiveYears)
        }
        let p = plan(.fiveYears, completions: five)
        #expect(p.covers(.steps, depth: .oneYear))
        #expect(!p.covers(.steps, depth: .all))
    }

    @Test func blockedKindNeverCountsAsComplete() {
        var completions: [String: HealthKindCompletion] = [:]
        for kind in HealthDataKind.allCases {
            completions[kind.rawValue] = HealthKindCompletion(
                recentCompletedAt: Date(), historyCompletedAt: Date(),
                historyDepth: .oneYear, blocked: kind == .sleep)
        }
        let p = plan(.oneYear, completions: completions)
        #expect(p.remainingKinds(depth: .oneYear) == [.sleep])
        #expect(p.mode(depth: .oneYear).isInitial)
    }

    @Test func coveredPlanUsesIncrementalModeEvenWithNewPendingWork() {
        var completions: [String: HealthKindCompletion] = [:]
        for kind in HealthDataKind.allCases {
            completions[kind.rawValue] = HealthKindCompletion(
                recentCompletedAt: Date(), historyCompletedAt: Date(), historyDepth: .oneYear)
        }
        let p = plan(.oneYear, completions: completions)
        // 业主裁决：已成功完整导入后只更新缺失部分；完成后的新 pending 属增量。
        #expect(p.mode(depth: .oneYear) == .incremental)
    }

    @Test func scopesAddFloorForLimitedDepthAndOmitEmptyHistory() throws {
        let connectedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let one = HealthFetchScope.scopes(connectedAt: connectedAt, calendar: calendar, depth: .oneYear)
        #expect(one.map(\.lane) == [.recent])

        let five = HealthFetchScope.scopes(connectedAt: connectedAt, calendar: calendar, depth: .fiveYears)
        #expect(five.map(\.lane) == [.recent, .history])
        let history = try #require(five.last)
        let floor = try #require(history.historyFloor)
        #expect(floor < history.cutoff)

        let all = HealthFetchScope.scopes(connectedAt: connectedAt, calendar: calendar, depth: .all)
        #expect(all.map(\.lane) == [.recent, .history])
        #expect(all.last?.historyFloor == nil)
    }

    @Test func historyFloorIsAppliedByMatches() {
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let floor = cutoff.addingTimeInterval(-1_000)
        let scope = HealthFetchScope(lane: .history, cutoff: cutoff, historyFloor: floor)
        func ref(_ end: Date) -> HealthSampleReference {
            HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "w", start: end, end: end)
        }
        #expect(scope.matches(ref(cutoff.addingTimeInterval(-1))))
        #expect(scope.matches(ref(floor)))
        #expect(!scope.matches(ref(floor.addingTimeInterval(-1))))
        #expect(!scope.matches(ref(cutoff)))
    }
}
