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

    @Test func 叙事新键整行或剥已知标签后接受_简繁英() {
        let lines = ["既往史：高血压 10 年", "過敏史：青黴素", "Storage: Keep below 25°C", "注意事项：饭后服用", "现病史：咳嗽 3 天", "体格检查：T 36.8℃", "就诊总结：对症处理", "病情说明：好转", "临床诊断：上呼吸道感染"]
        let fields = OCRGrounding.fields([
            .init(key: "clinical_diagnosis", value: "上呼吸道感染", lineIndex: 8),
            .init(key: "past_history", value: "高血压 10 年", lineIndex: 0),
            .init(key: "allergy_history", value: "青黴素", lineIndex: 1),
            .init(key: "medication_notes", value: "Keep below 25°C", lineIndex: 2),
            .init(key: "medication_notes", value: "饭后服用", lineIndex: 3),
            .init(key: "present_illness", value: "咳嗽 3 天", lineIndex: 4),
            .init(key: "physical_exam", value: "T 36.8℃", lineIndex: 5),
            .init(key: "visit_summary", value: "对症处理", lineIndex: 6),
            .init(key: "illness_summary", value: "好转", lineIndex: 7),
            .init(key: "past_history", value: "高血压", lineIndex: 0),          // 叙事截断：既非整行也非标签值
        ], lines: lines)
        #expect(fields.map(\.value) == ["上呼吸道感染", "高血压 10 年", "青黴素", "Keep below 25°C", "饭后服用", "咳嗽 3 天", "T 36.8℃", "对症处理", "好转"])
        #expect(fields.allSatisfy { $0.grade == .ocrUnconfirmed })
    }

    @Test func 新数值键子串防线与处方类型归一() {
        let fields = OCRGrounding.fields([
            .init(key: "total_amount", value: "28.5", lineIndex: 0),
            .init(key: "total_amount", value: "128.50", lineIndex: 0),
            .init(key: "item_amount", value: "25.00", lineIndex: 1),
            .init(key: "unit_price", value: "5.00", lineIndex: 1),
            .init(key: "personal_account_amount", value: "8", lineIndex: 2),
            .init(key: "prescription_type", value: "中药", lineIndex: 3),
            .init(key: "fee_item", value: "血常规", lineIndex: 1),
            .init(key: "invoice_no", value: "No.0001", lineIndex: 4),
        ], lines: ["总计：128.50", "血常规 5.00 5 25.00", "个人账户支付 8 元", "处方类型：中药", "票据号 No.0001"])
        #expect(fields.map(\.key) == ["total_amount", "item_amount", "unit_price", "personal_account_amount", "prescription_type", "fee_item", "invoice_no"])
        #expect(fields.first { $0.key == "total_amount" }?.value == "128.50")
        #expect(fields.first { $0.key == "prescription_type" }?.value == "tcm", "打印类型标签归一为 canonical raw（同 item_type/unit_kind）")
    }

    @Test func 完整卡：批量确认不覆盖必填，逐项确认必填后方可保存() {
        let card = MatchedCard(kind: "prescription", pageIndex: 0,
            shared: [.init(key: "prescribed_at", value: "2026-09-11", confidence: 0.9)],
            rows: [.init(fields: [.init(key: "drug_name", value: "阿莫西林", confidence: 0.9)])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        #expect(card.allFields.allSatisfy { !$0.isConfirmed }, "原卡不提前升 C")

        // 2026-09-17 业主定「信息卡中的必要字段必须逐一确认」：
        // prescription 的 sharedRequired = {prescribed_at}、rowRequired = {drug_name}，
        // 二者均**不参与**卡级批量确认 → 批量后仍不可保存——`invalidFields` 挡住保存，
        // 这正是「强制逐一确认」的执行机制（旧版此处靠低置信挡，现改为按必填挡）。
        let bulkOnly = card.confirmingAllFields()
        let blocked = EntityCardProjection.invalidFields(in: bulkOnly, row: bulkOnly.rows[0], calendar: .current)
        #expect(Set(blocked) == ["drug_name", "prescribed_at"],
                "必填未被批量覆盖 → 保存被挡（强制逐项确认）；实得 \(blocked)")

        // 逐项确认必填（新流程第二步）→ 可保存
        let done = card.fullyConfirmed()
        #expect(EntityCardProjection.invalidFields(in: done, row: done.rows[0], calendar: .current).isEmpty,
                "必填逐一确认后可保存")
    }
}
