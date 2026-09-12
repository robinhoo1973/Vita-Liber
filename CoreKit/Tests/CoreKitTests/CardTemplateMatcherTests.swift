import Foundation
import Testing
@testable import Domain

// binds: SU-M2-PENDINGCARD
/// FR6.9（V3.61 业主裁决）：单页识别文本对每个卡模板做匹配——**全字段 ≥50% 且必填 ≥80%**
/// 可从文本获取即匹配该卡；同类多实例每类一卡、卡内多行；同一卡类跨页各成一卡。
/// 纯 Domain，Linux 可跑。
@Suite("SU-M2-PENDINGCARD · 卡模板双阈值匹配（FR6.9 V3.61）")
struct CardTemplateMatcherTests {
    @Test(arguments: ["", "  \n "])
    func emptyFieldsDoNotSatisfyRequiredCoverage(_ value: String) {
        let fields = [FieldDraft(key: "report_date", value: value),
                      FieldDraft(key: "lab_item", value: "Hb 150", unit: "g/L")]
        #expect(CardTemplateMatcher.match(fields: fields, pageIndex: 0,
                                          documentTypeKey: "lab_report").isEmpty)
    }

    @Test func ambiguousSameTextRangesAreNotAssignedToEveryRow() {
        let raw = "A 1 g/L 0-2 B 3 g/L 2-4"
        let fields = [FieldDraft(key: "report_date", value: "2026-09-01"),
                      FieldDraft(key: "lab_item", value: "A 1", unit: "g/L", rawText: raw),
                      FieldDraft(key: "lab_item", value: "B 3", unit: "g/L", rawText: raw),
                      FieldDraft(key: "reference_range", value: "0-2", rawText: raw),
                      FieldDraft(key: "reference_range", value: "2-4", rawText: raw)]
        let card = CardTemplateMatcher.match(fields: fields, pageIndex: 0,
                                             documentTypeKey: "lab_report").first
        #expect(card?.rows.count == 2)
        #expect(card?.rows.allSatisfy { row in
            !row.fields.contains { $0.key == "ref_low" || $0.key == "ref_high" }
        } == true)
    }


    private func labItem(_ name: String, _ value: String, unit: String? = "g/L", raw: String? = nil) -> FieldDraft {
        FieldDraft(key: "lab_item", value: "\(name) \(value)", unit: unit, confidence: 0.6,
                   rawText: raw ?? "\(name) \(value) \(unit ?? "")")
    }

    @Test("检验页 10 项 + 报告日期 → 1 张 metric_sample 卡 10 行，日期为卡级共享字段")
    func 检验页十项目一卡十行() {
        var fields = [FieldDraft(key: "report_date", value: "2026-09-01", confidence: 0.6, rawText: "日期：2026-09-01")]
        for i in 0..<10 { fields.append(labItem("项目\(i)", "\(100 + i)")) }
        let cards = CardTemplateMatcher.match(fields: fields, pageIndex: 2, documentTypeKey: "lab_report")
        let metric = cards.first { $0.kind == "metric_sample" }
        #expect(metric != nil)
        #expect(metric?.rows.count == 10)
        #expect(metric?.pageIndex == 2)
        #expect(metric?.shared.contains { $0.key == "measured_at" && $0.value == "2026-09-01" } == true)
        #expect(metric?.rows.first?.fields.contains { $0.key == "raw_label" && $0.value == "项目0" } == true)
        #expect(metric?.rows.first?.fields.contains { $0.key == "value" && $0.value == "100" } == true)
        #expect(metric?.rows.first?.fields.contains { $0.key == "unit" && $0.value == "g/L" } == true)
        #expect(cards.contains { $0.kind == "encounter" } == false, "检验报告不派生就诊卡")
        #expect(cards.contains { $0.kind == "document_file" } == false, "文档卡不经匹配器（恒存在）")
    }

    @Test("无报告日期 → measured_at 缺失，必填覆盖 3/4 < 80%，不出指标卡")
    func 无日期不出指标卡() {
        let fields = (0..<3).map { labItem("项目\($0)", "5", unit: "mmol/L") }
        #expect(CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "lab_report").isEmpty)
    }

    @Test("阈值边界：全字段 ≥50% 与必填 ≥80% 同时满足才匹配，任一不足即不出卡")
    func 阈值边界() {
        // metric_sample 模板 8 字段（metric_key/value/unit/measured_at 必填 + ref_low/ref_high/raw_label/code_concept_id）
        // 覆盖 raw_label/metric_key(派生)/value/unit/measured_at = 5/8 = 0.625 ≥ 0.5；必填 4/4
        let ok = [FieldDraft(key: "report_date", value: "2026-09-01", confidence: 0.6), labItem("血红蛋白", "150")]
        #expect(CardTemplateMatcher.match(fields: ok, pageIndex: 0, documentTypeKey: "lab_report").count == 1)
        // 去掉单位：必填 3/4 = 0.75 < 0.8 → 不匹配（全字段 4/8 = 0.5 仍达线，证明必填线独立起效）
        let noUnit = [FieldDraft(key: "report_date", value: "2026-09-01", confidence: 0.6), labItem("血红蛋白", "150", unit: nil)]
        #expect(CardTemplateMatcher.match(fields: noUnit, pageIndex: 0, documentTypeKey: "lab_report").isEmpty)
        // encounter 模板 6 字段（date/kind 必填 + hospital/department/doctor/chief_complaint）：
        // date + kind(派生) = 2/6 = 0.33 < 0.5 → 不匹配；加 dept → 3/6 = 0.5 → 匹配
        let two = [FieldDraft(key: "report_date", value: "2026-09-01", confidence: 0.6)]
        #expect(CardTemplateMatcher.match(fields: two, pageIndex: 0, documentTypeKey: "outpatient_record").isEmpty)
        let three = two + [FieldDraft(key: "dept", value: "心内科", confidence: 0.6)]
        #expect(CardTemplateMatcher.match(fields: three, pageIndex: 0, documentTypeKey: "outpatient_record").count == 1)
    }

    @Test("病历页就诊卡只在门诊病历/诊断证明判定下产生（kind 由判定派生）")
    func 就诊卡需类型判定() {
        let fields = [FieldDraft(key: "report_date", value: "2026-09-01", confidence: 0.6),
                      FieldDraft(key: "dept", value: "心内科", confidence: 0.6),
                      FieldDraft(key: "diagnosis", value: "高血压 2 级", confidence: 0.6)]
        let clinic = CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "outpatient_record")
        let encounter = clinic.first { $0.kind == "encounter" }
        #expect(encounter?.rows.count == 1)
        #expect(encounter?.shared.contains { $0.key == "kind" && $0.value == EncounterKind.outpatient.rawValue } == true)
        #expect(encounter?.shared.contains { $0.key == "department" && $0.value == "心内科" } == true)
        #expect(encounter?.shared.contains { $0.key == "diagnosis_text" } == true)
        #expect(CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "lab_report").isEmpty)
        #expect(CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: nil).isEmpty)
    }

    @Test("处方页三药 → prescription 1 卡 3 行，日期/医院共享")
    func 处方页每药一行() {
        let fields = [FieldDraft(key: "drug_name", value: "阿莫西林胶囊", confidence: 0.9),
                      FieldDraft(key: "drug_name", value: "布洛芬缓释胶囊", confidence: 0.9),
                      FieldDraft(key: "drug_name", value: "维生素 C", confidence: 0.9),
                      FieldDraft(key: "prescribed_at", value: "2026-09-01", confidence: 0.9),
                      FieldDraft(key: "hospital", value: "市一医院", confidence: 0.9)]
        let cards = CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "prescription")
        let rx = cards.first { $0.kind == "prescription" }
        #expect(rx?.rows.count == 3)
        #expect(rx?.shared.map(\.key).sorted() == ["hospital", "prescribed_at"])
        #expect(rx?.allFieldCoverage == 3.0 / 5.0)
        #expect(rx?.requiredCoverage == 1)
        #expect(rx?.level == .basicallyComplete, "必填全在但 doctor/advice_text 缺失 → 基本完整（徽章不决定建卡）")
    }

    @Test("同 rawText 行的参考范围拆入该检验行（ref_low/ref_high），不作卡级共享")
    func 参考范围归行() {
        let line = "白细胞 6.5 10^9/L 3.5-9.5"
        let drafts = DocumentTypeClassifierFallback.guessFields(line: line)
        #expect(drafts.map(\.key).sorted() == ["lab_item", "reference_range"])
        #expect(drafts.first { $0.key == "reference_range" }?.value == "3.5-9.5")
        var fields = drafts + [FieldDraft(key: "report_date", value: "2026-09-01", confidence: 0.6)]
        fields += DocumentTypeClassifierFallback.guessFields(line: "血红蛋白 150 g/L")
        let card = CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "lab_report").first
        #expect(card?.rows.count == 2)
        let wbc = card?.rows.first { $0.fields.contains { $0.key == "raw_label" && $0.value == "白细胞" } }
        #expect(wbc?.fields.contains { $0.key == "ref_low" && $0.value == "3.5" } == true)
        #expect(wbc?.fields.contains { $0.key == "ref_high" && $0.value == "9.5" } == true)
        let hgb = card?.rows.first { $0.fields.contains { $0.key == "raw_label" && $0.value == "血红蛋白" } }
        #expect(hgb?.fields.contains { $0.key == "ref_low" } == false)
        #expect(card?.shared.contains { $0.key == "ref_low" } == false)
    }

    @Test("同一卡类跨页各成一卡；每卡携带自己的页号")
    func 跨页各成一卡() {
        let page = [FieldDraft(key: "report_date", value: "2026-09-01", confidence: 0.6), labItem("血糖", "5.6", unit: "mmol/L")]
        let p0 = CardTemplateMatcher.match(fields: page, pageIndex: 0, documentTypeKey: "lab_report")
        let p1 = CardTemplateMatcher.match(fields: page, pageIndex: 1, documentTypeKey: "lab_report")
        #expect(p0.count == 1 && p1.count == 1)
        #expect(p0[0].pageIndex == 0 && p1[0].pageIndex == 1)
        #expect(p0[0].id != p1[0].id)
    }

    @Test("行级必填缺失：卡级仍匹配，该行标记 missingRequired，保存时跳过不阻断其他行")
    func 行级必填缺失标记() {
        let fields = [FieldDraft(key: "report_date", value: "2026-09-01", confidence: 0.6),
                      labItem("血红蛋白", "150"), labItem("红细胞", "4.5", unit: nil)]
        let card = CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "lab_report").first
        #expect(card?.rows.count == 2)
        let missing = card?.rows.first { !$0.missingRequired.isEmpty }
        #expect(missing?.missingRequired == ["unit"])
        #expect(card?.missingRequired.isEmpty == true, "卡级必填（去重键）全部覆盖")
    }

    @Test("目录登记但无提取器的卡类（medication/immunization/appointment/claim_item）恒不匹配")
    func 无提取器卡类不匹配() {
        let kinds = Set(CardTemplateMatcher.ocrTemplates.map(\.kind))
        #expect(kinds.isSuperset(of: ["metric_sample", "encounter", "prescription", "medication", "immunization", "appointment", "claim_item"]))
        let rich = [FieldDraft(key: "report_date", value: "2026-09-01", confidence: 0.6),
                    FieldDraft(key: "dept", value: "内科", confidence: 0.6),
                    FieldDraft(key: "drug_name", value: "阿莫西林", confidence: 0.9),
                    FieldDraft(key: "prescribed_at", value: "2026-09-01", confidence: 0.9),
                    labItem("血糖", "5.6", unit: "mmol/L")]
        let produced = Set(CardTemplateMatcher.match(fields: rich, pageIndex: 0, documentTypeKey: "outpatient_record").map(\.kind))
        #expect(produced.isDisjoint(with: ["medication", "immunization", "appointment", "claim_item", "document_file"]))
    }

    @Test("阈值常量为 Domain 单一事实源")
    func 阈值常量() {
        #expect(CardMatchThresholds.allFields == 0.5)
        #expect(CardMatchThresholds.requiredFields == 0.8)
    }

    @Test func hospitalAndSameTextDateSurviveCompanionMatching() {
        let raw = "Report 2026-09-01 A 12 g/L"
        let fields = [FieldDraft(key: "report_date", value: "2026-09-01", rawText: raw),
                      FieldDraft(key: "hospital", value: "Hospital", rawText: raw),
                      FieldDraft(key: "lab_item", value: "A 12", unit: "g/L", rawText: raw)]
        let card = CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "lab_report").first
        #expect(card?.shared.contains { $0.key == "hospital" && $0.value == "Hospital" } == true)
        #expect(card?.allFieldCoverage == 5.0 / 8.0)
    }

    @Test func signedRangesAreParsedAndReversedOrInfiniteRangesAreRejected() {
        #expect(CardTemplateMatcher.referenceBounds("-2 - 2")?.0 == "-2")
        #expect(CardTemplateMatcher.referenceBounds("2-1") == nil)
        #expect(CardTemplateMatcher.referenceBounds("1-1e999") == nil)
    }

    @Test("检验行目录次序（值-范围-单位）与冒号无空格均成行（round10 修复）")
    func catalogOrderLabLinesMatch() {
        let drafts = DocumentTypeClassifierFallback.guessFields(line: "血红蛋白 150 115-150 g/L")
        #expect(drafts.map(\.key).sorted() == ["lab_item", "reference_range"])
        #expect(drafts.first { $0.key == "lab_item" }?.value == "血红蛋白 150")
        #expect(drafts.first { $0.key == "lab_item" }?.unit == "g/L")
        #expect(drafts.first { $0.key == "reference_range" }?.value == "115-150")
        let colon = DocumentTypeClassifierFallback.guessFields(line: "血红蛋白：150")
        #expect(colon.first?.key == "lab_item")
        #expect(colon.first?.value == "血红蛋白 150")
    }

    @Test("多行用法/用量并入同一 advice_text，不静默丢行（round10 修复）")
    func multiLineDirectionsMergeIntoAdvice() {
        // 真实处方页字段集：覆盖率门禁（allFields 0.5 + 必填 drug_name/
        // prescribed_at 全中）通过后卡才产出——只喂 advice×2 + 药名时
        // coverage=2/5 拒卡，advice 恒空（CI 34672163937 实证：断言空串）。
        let fields = [
            FieldDraft(key: "advice_text", value: "用法：口服", confidence: 0.6),
            FieldDraft(key: "advice_text", value: "用量：每次1片", confidence: 0.6),
            FieldDraft(key: "drug_name", value: "阿莫西林", confidence: 0.6),
            FieldDraft(key: "prescribed_at", value: "2026-09-10", confidence: 0.6),
            FieldDraft(key: "hospital", value: "市一医院", confidence: 0.6),
            FieldDraft(key: "doctor", value: "王医生", confidence: 0.6),
        ]
        let card = CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "prescription")
            .first { $0.kind == "prescription" }
        #expect(card != nil, "处方卡必须过覆盖率门禁产出")
        let advice = card?.shared.first { $0.key == "advice_text" }?.value ?? ""
        #expect(advice.contains("口服"))
        #expect(advice.contains("每次1片"))
    }

    @Test("同一原文行模型轨与启发式轨双产出时保留含数值载荷（round10 O8）")
    func dualTrackLabDraftsKeepNumericPayload() {
        let lines = ["血红蛋白 150"]
        let llm = FieldDraft(key: "lab_item", value: "血红蛋白", confidence: 0.9,
                             rawText: "血红蛋白 150", source: .foundationModels)
        let fields = DocumentTypeClassifierFallback.pageFields(lines: lines, understood: [llm], confidence: 0.9)
        let labs = fields.filter { $0.key == "lab_item" }
        #expect(labs.count == 1)
        #expect(labs.first?.value == "血红蛋白 150")
    }
}
