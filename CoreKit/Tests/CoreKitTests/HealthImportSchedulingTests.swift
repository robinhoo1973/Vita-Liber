import Testing
import Foundation
@testable import Domain

/// 业主 2026-10-20：受限轮次的类型轮转与预算均分（睡眠不再被心率饿死）。
struct HealthImportSchedulingTests {

    @Test func rotationStartsAtRequestedIndexAndWraps() {
        let kinds: [HealthDataKind] = [.heartRate, .steps, .sleep]
        #expect(HealthImportScheduling.rotated(kinds, startingAt: 0) == kinds)
        #expect(HealthImportScheduling.rotated(kinds, startingAt: 1) == [.steps, .sleep, .heartRate])
        #expect(HealthImportScheduling.rotated(kinds, startingAt: 3) == kinds)
        #expect(HealthImportScheduling.rotated(kinds, startingAt: -1) == [.sleep, .heartRate, .steps])
        #expect(HealthImportScheduling.rotated([], startingAt: 2).isEmpty)
    }

    @Test func shareSplitsRemainingBudgetEvenlyAndClampsNegatives() {
        #expect(HealthImportScheduling.share(remaining: .seconds(30), kindsLeft: 6) == .seconds(5))
        #expect(HealthImportScheduling.share(remaining: .seconds(1), kindsLeft: 4) == .milliseconds(250))
        #expect(HealthImportScheduling.share(remaining: .seconds(-1), kindsLeft: 6) == .zero)
        #expect(HealthImportScheduling.share(remaining: .seconds(30), kindsLeft: 0) == .zero)
    }
}
