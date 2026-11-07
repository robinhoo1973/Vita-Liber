import Testing
import Foundation
@testable import Domain

@Suite("Extraction rule overlay")
struct ExtractionRuleOverlayTests {
    private let spec = ExtractionSpecRegistry.spec(for: "prescription")!

    @Test("active aliases append without changing keys, types or order")
    func appliesAdditively() {
        let overlay = ExtractionRuleOverlay(aliases: [
            ExtractionRuleAlias(kind: "prescription", key: "department", alias: "开单科室",
                                source: .scanMined, status: .active),
            ExtractionRuleAlias(kind: "prescription", key: "department", alias: "不应出现",
                                source: .scanMined, status: .proposed),
        ])
        let applied = overlay.applied(to: spec)
        #expect(applied.fields.map(\.key) == spec.fields.map(\.key))
        #expect(applied.fields.map(\.type) == spec.fields.map(\.type))
        let department = applied.field(for: "department")
        #expect(department?.labelAliases.contains("开单科室") == true)
        #expect(department?.labelAliases.contains("不应出现") == false)
        #expect(applied.kind == spec.kind)
        #expect(applied.rowAnchor == spec.rowAnchor)
    }

    @Test("only active rows are read")
    func activeOnly() {
        let overlay = ExtractionRuleOverlay(aliases: [
            ExtractionRuleAlias(kind: "encounter", key: "doctor", alias: "接诊医师",
                                source: .coreMLObserved, status: .active),
            ExtractionRuleAlias(kind: "encounter", key: "doctor", alias: "备注医师",
                                source: .coreMLObserved, status: .proposed),
        ])
        #expect(overlay.activeAliases(for: "encounter")["doctor"] == ["接诊医师"])
    }

    @Test("learned alias is flagged for the 0.5 confidence cap")
    func learnedFlag() {
        let overlay = ExtractionRuleOverlay(aliases: [
            ExtractionRuleAlias(kind: "prescription", key: "drug_name", alias: "开单药品",
                                source: .coreMLObserved, status: .active),
            ExtractionRuleAlias(kind: "prescription", key: "spec", alias: "包装",
                                source: .scanMined, status: .active),
        ])
        #expect(overlay.hasLearnedAlias(kind: "prescription", key: "drug_name"))
        #expect(!overlay.hasLearnedAlias(kind: "prescription", key: "spec"))
    }

    @Test("generic labeled value only accepts label-like prefixes")
    func genericLabel() {
        #expect(RuleExtractor.genericLabeledValue(in: "申请科室：骨科门诊")?.label == "申请科室")
        #expect(RuleExtractor.genericLabeledValue(in: "申请科室：骨科门诊")?.value == "骨科门诊")
        #expect(RuleExtractor.genericLabeledValue(in: "1234：值") == nil)
        #expect(RuleExtractor.genericLabeledValue(in: "没有冒号的行") == nil)
    }
}
