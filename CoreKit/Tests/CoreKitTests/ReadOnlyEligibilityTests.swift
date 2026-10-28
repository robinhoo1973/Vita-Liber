import Testing
@testable import Domain

/// 只读降级适格矩阵（2026-10-28 规划轮 round1；四席收敛：首批仅 tooNew）。
/// 钉死两件事：1) 全决策类矩阵逐一断言；2) 标签常量与 `isEligible` 双向一致。
@Suite("SU-M2-READONLY-ELIGIBLE · 只读降级适格策略")
struct ReadOnlyEligibilityTests {

    @Test func onlyTooNewIsEligible() {
        #expect(ReadOnlyDegradation.isEligible(.tooNew(found: 50, supported: 49)))
        #expect(!ReadOnlyDegradation.isEligible(.fresh))
        #expect(!ReadOnlyDegradation.isEligible(.ready(version: 49)))
        #expect(!ReadOnlyDegradation.isEligible(.migrate(from: 48, to: 49)))
        #expect(!ReadOnlyDegradation.isEligible(.missingWithOriginals))
    }

    @Test(arguments: [
        DatabaseBootDecision.CorruptReason.emptyFile,
        .badHeader, .unreadableVersion, .versionZeroWithTables, .missingRequiredTables,
    ])
    func corruptReasonsAreNeverEligible(reason: DatabaseBootDecision.CorruptReason) {
        #expect(!ReadOnlyDegradation.isEligible(.corrupt(reason)),
                "corrupt(\(reason.rawValue)) 不得进入只读降级（安全席红线口径）")
    }

    @Test func labelsAndEligibilitySetAreMirrors() {
        let decisions: [DatabaseBootDecision] = [
            .fresh, .ready(version: 49), .migrate(from: 48, to: 49),
            .tooNew(found: 50, supported: 49), .missingWithOriginals,
            .corrupt(.emptyFile), .corrupt(.badHeader), .corrupt(.unreadableVersion),
            .corrupt(.versionZeroWithTables), .corrupt(.missingRequiredTables),
        ]
        // 双向一致：标签集成员 ⟺ isEligible 为真。
        for decision in decisions {
            let inSet = ReadOnlyDegradation.eligibleDecisionLabels
                .contains(ReadOnlyDegradation.label(for: decision))
            #expect(inSet == ReadOnlyDegradation.isEligible(decision),
                    "label 集与 isEligible 失配：\(ReadOnlyDegradation.label(for: decision))")
        }
        // 适格集恰为一个成员（新增须重审并改此钉版）。
        #expect(ReadOnlyDegradation.eligibleDecisionLabels == ["tooNew"])
    }
}
