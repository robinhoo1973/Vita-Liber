import Foundation
import Testing
@testable import Domain

@Suite("FR17.18 OCR 原文锚定与卡级确认")
struct OCRGroundingTests {
    @Test func 抽取字段必须存在于指定原文行() {
        let lines = ["药品：阿莫西林", "金额：128.50元"]
        let candidates = [
            OCRExtractedSpan(key: "drug_name", value: "阿莫西林", lineIndex: 0),
            OCRExtractedSpan(key: "amount", value: "999.00", lineIndex: 1),
            OCRExtractedSpan(key: "diagnosis", value: "阿莫西林", lineIndex: 99),
            OCRExtractedSpan(key: "execute", value: "128.50", lineIndex: 1),
        ]
        let fields = OCRGrounding.fields(candidates, lines: lines)
        #expect(fields.map(\.key) == ["drug_name"])
        #expect(fields.first?.value == "阿莫西林")
        #expect(fields.first?.grade == .ocrUnconfirmed)
        #expect(fields.first?.rawText == lines[0])
    }

    @Test func 否定符号和单位不能被模型删改() {
        let lines = ["未诊断糖尿病", "血糖 <3.9 mmol/L"]
        let fields = OCRGrounding.fields([
            .init(key: "diagnosis", value: "糖尿病", lineIndex: 0),
            .init(key: "lab_item", value: "血糖 3.9", unit: "mg/dL", lineIndex: 1),
        ], lines: lines)
        #expect(fields.isEmpty)
    }

    @Test func 不允许截断检验小数或移除英文停药指令() {
        let fields = OCRGrounding.fields([
            .init(key: "lab_item", value: "血糖 5", unit: "mmol/L", lineIndex: 0),
            .init(key: "drug_name", value: "aspirin", lineIndex: 1),
            .init(key: "lab_item", value: "Hb 150", unit: "g", lineIndex: 2),
        ], lines: ["血糖 5.9 mmol/L", "Do not take aspirin", "Hb 150 mg/L"])
        #expect(fields.isEmpty)
    }

    @Test func 完整卡一次显式确认而原卡不提前升C() {
        let card = MatchedCard(kind: "prescription", pageIndex: 0,
            shared: [.init(key: "prescribed_at", value: "2026-09-11", confidence: 0.6)],
            rows: [.init(fields: [.init(key: "drug_name", value: "阿莫西林", confidence: 0.6)])],
            allFieldCoverage: 0.6, requiredCoverage: 1, missingRequired: [], level: .basicallyComplete)
        let reviewed = card.confirmingAllFields()
        #expect(EntityCardProjection.invalidFields(in: reviewed, row: reviewed.rows[0], calendar: .current).isEmpty)
        #expect(card.allFields.allSatisfy { !$0.isConfirmed })
        var low = card; low.rows[0].fields[0].confidence = 0.1
        let blocked = low.confirmingAllFields()
        #expect(EntityCardProjection.invalidFields(in: blocked, row: blocked.rows[0], calendar: .current).contains("drug_name"))
    }
}
