import Foundation
import Testing
@testable import Domain

@Suite("SU-M2-F16 健康同步周期与间隔")
struct HealthSyncScheduleTests {
    @Test("间隔只接受小时档；非法值回落 4 小时")
    func intervalResolution() {
        #expect(HealthSyncInterval.resolved("60") == .hourly)
        #expect(HealthSyncInterval.resolved("480") == .eightHours)
        #expect(HealthSyncInterval.resolved("30") == .default)
        #expect(HealthSyncInterval.resolved(nil) == .default)
        #expect(HealthSyncInterval.resolved("oops") == .default)
    }

    @Test("完成后未到间隔不开始新周期；到期/无完成记录开始")
    func dueRules() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(HealthSyncCycleRules.isDue(lastCompletedAt: nil, now: now, interval: .hourly))
        #expect(!HealthSyncCycleRules.isDue(
            lastCompletedAt: now.addingTimeInterval(-3_599), now: now, interval: .hourly))
        #expect(HealthSyncCycleRules.isDue(
            lastCompletedAt: now.addingTimeInterval(-3_600), now: now, interval: .hourly))
        #expect(!HealthSyncCycleRules.isDue(
            lastCompletedAt: now.addingTimeInterval(-3 * 3_600), now: now, interval: .fourHours))
    }

    @Test("待同步类别 = allCases 去掉本周期已稳定类别")
    func pendingKinds() {
        let stable: Set<HealthDataKind> = [.sleep, .steps]
        let pending = HealthSyncCycleRules.pendingKinds(stable)
        #expect(pending == HealthDataKind.allCases.filter { $0 != .sleep && $0 != .steps })
        #expect(!HealthSyncCycleRules.allStable(stable))
        #expect(HealthSyncCycleRules.allStable(Set(HealthDataKind.allCases)))
    }

    @Test("周期状态机")
    func cycleState() {
        let idle = HealthSyncCycleState()
        #expect(idle.isInitial && !idle.isActive && !idle.isComplete)
        let active = HealthSyncCycleState(startedAt: Date(), stableKinds: [.sleep])
        #expect(active.isActive && !active.isComplete)
        let done = HealthSyncCycleState(startedAt: Date(), completedAt: Date(),
                                        stableKinds: Set(HealthDataKind.allCases))
        #expect(!done.isActive && done.isComplete)
    }
}
