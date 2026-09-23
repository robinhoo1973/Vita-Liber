import Foundation
import Testing
import Domain

/// SU-M2-DOSE-CONFLICT：FR9.19 用药冲突提示（V4.04）。
/// 纯排程事实（BR-006）：餐时窗互斥提示、间距阈值注入（provider 无值 → 不出现）。
@Suite("SU-M2-DOSE-CONFLICT FR9.19 用药冲突提示")
struct DoseConflictRulesTests {

    private let base = Date(timeIntervalSince1970: 1_790_000_000)   // 固定时刻，免时区波动

    private func ref(_ id: String, _ label: String, offsetMinutes: Int, meal: String?) -> DoseConflictRules.DoseRef {
        DoseConflictRules.DoseRef(id: id, label: label,
                                  dueAt: base.addingTimeInterval(Double(offsetMinutes) * 60),
                                  mealRelation: meal)
    }

    @Test("同窗内空腹族与餐后族混合 → 餐时窗互斥提示（排程事实）")
    func mealWindowMismatchWithinTolerance() {
        let conflicts = DoseConflictRules.conflicts(
            doses: [ref("a", "药A", offsetMinutes: 0, meal: "beforeBreakfast"),
                    ref("b", "药B", offsetMinutes: 10, meal: "afterBreakfast")],
            spacingThresholdMinutes: nil)
        #expect(conflicts == [.mealWindowMismatch(first: "药A", second: "药B", at: base.addingTimeInterval(600))])
    }

    @Test("同为餐后族 → 不产生互斥提示")
    func sameFamilyNoMismatch() {
        let conflicts = DoseConflictRules.conflicts(
            doses: [ref("a", "药A", offsetMinutes: 0, meal: "afterLunch"),
                    ref("b", "药B", offsetMinutes: 5, meal: "afterDinner")],
            spacingThresholdMinutes: nil)
        #expect(conflicts.isEmpty)
    }

    @Test("间距阈值为 nil（GuidelineSource 未过医学审核闸）→ 间距类提示整体不出现")
    func nilThresholdSuppressesSpacingHints() {
        let conflicts = DoseConflictRules.conflicts(
            doses: [ref("a", "药A", offsetMinutes: 0, meal: nil),
                    ref("b", "药B", offsetMinutes: 5, meal: nil)],
            spacingThresholdMinutes: nil)
        #expect(conflicts.isEmpty)
    }

    @Test("间距阈值 120 分钟、实际间隔 60 分钟 → 出现间距提示")
    func spacingBelowThresholdReported() {
        let conflicts = DoseConflictRules.conflicts(
            doses: [ref("a", "药A", offsetMinutes: 0, meal: nil),
                    ref("b", "药B", offsetMinutes: 60, meal: nil)],
            spacingThresholdMinutes: 120)
        #expect(conflicts == [.spacingBelowThreshold(first: "药A", second: "药B",
                                                     gapMinutes: 60, thresholdMinutes: 120)])
    }

    @Test("间隔恰好等于阈值 → 不报（< 才报）；输入乱序亦按时间排序")
    func boundaryAndOrdering() {
        let conflicts = DoseConflictRules.conflicts(
            doses: [ref("b", "药B", offsetMinutes: 60, meal: nil),
                    ref("a", "药A", offsetMinutes: 0, meal: nil)],
            spacingThresholdMinutes: 60)
        #expect(conflicts.isEmpty)
    }
}
