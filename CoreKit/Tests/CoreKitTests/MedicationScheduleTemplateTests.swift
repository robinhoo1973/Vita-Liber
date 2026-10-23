import Foundation
import Testing
@testable import Domain

// binds: FR9.4 用药计划时段模板（v42 与药品解耦，2026-10-23 业主）
@Suite("MedicationScheduleTemplateRules 校验与规范化")
struct MedicationScheduleTemplateTests {
    @Test("规范化：非法剔除、按分钟去重、升序")
    func normalizeDedupesAndSorts() {
        let times = MedicationScheduleTemplateRules.normalize(
            ["19:30", "07:30", "bad", "7:30", "07:00"])
        #expect(times == ["07:00", "07:30", "19:30"])
    }

    @Test("校验：空/非法/重复分别拒绝")
    func validationRejects() {
        #expect(MedicationScheduleTemplateRules.validate([]) == .empty)
        #expect(MedicationScheduleTemplateRules.validate([" "]) == .empty)
        #expect(MedicationScheduleTemplateRules.validate(["25:99"]) == .invalidTime)
        #expect(MedicationScheduleTemplateRules.validate(["08:30", "8:30"]) == .duplicateTime)
        #expect(MedicationScheduleTemplateRules.validate(["08:30", "19:30"]) == nil)
    }

    @Test("摘要：规范顺序与分隔符")
    func summaryText() {
        #expect(MedicationScheduleTemplateRules.summary(["19:30", "07:30"]) == "07:30 · 19:30")
        #expect(MedicationScheduleTemplateRules.summary([]) == "")
    }
}
