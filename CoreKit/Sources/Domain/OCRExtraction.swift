import Foundation

/// 模型只定位原文中的字段，不承担单位换算、诊断生成或药品剂量推断。
public struct OCRExtractedSpan: Sendable, Equatable {
    public let key: String
    public let value: String
    public let unit: String?
    public let lineIndex: Int
    public init(key: String, value: String, unit: String? = nil, lineIndex: Int) {
        self.key = key; self.value = value; self.unit = unit; self.lineIndex = lineIndex
    }
}

public enum OCRGrounding {
    /// 理解层键目录（模板键经 `CardTemplate.mapping` 映射；键集与 `CardKindRegistry` 同源扩展）。
    public static let allowedKeys: Set<String> = [
        "hospital", "doctor", "dept", "report_date", "prescribed_at", "chief_complaint",
        "diagnosis", "treatment", "present_illness", "illness_summary", "visit_summary",
        "lab_item", "reference_range", "drug_name", "advice_text", "generic_name", "brand_name",
        "spec", "unit_kind", "dosage", "quantity", "frequency", "route", "days", "note",
        "amount", "currency", "item_type", "merchant", "summary", "vaccine_name",
        "dose_number", "administered_at", "provider", "lot_number", "reimbursed_amount", "out_of_pocket",
        // v25 就诊叙事（§C.1）
        "past_history", "physical_exam", "allergy_history",
        // v25 处方表头 + 行（§C.6）
        "prescription_no", "prescription_type", "fee_type", "clinical_diagnosis", "pharmacist_names", "total_amount",
        "drug_form", "start_date", "end_date", "as_needed", "medication_notes", "insurance_code", "item_code", "unit_price", "line_amount",
        // v25 票据表头 + 费用明细行（§C.7）
        "personal_account_amount", "invoice_no", "insurance_type",
        "fee_item", "item_amount", "item_quantity", "item_spec", "fee_category", "executing_dept", "self_pay_ratio", "fee_at",
    ]
    public static let documentTypes: Set<String> = [
        "prescription", "lab_report", "outpatient_record", "diagnosis_certificate", "vaccine_record", "invoice", "medication_label",
    ]
    /// 叙事键：只接受整行或「已知标签：值」剥离，模型不得摘要/截断/改写（BR-002/003）。
    private static let narrativeKeys: Set<String> = [
        "diagnosis", "chief_complaint", "treatment", "advice_text", "summary",
        "present_illness", "illness_summary", "visit_summary",
        "past_history", "physical_exam", "allergy_history", "medication_notes", "clinical_diagnosis",
    ]
    private static let numericKeys: Set<String> = [
        "amount", "dose_number", "quantity", "days", "reimbursed_amount", "out_of_pocket",
        "total_amount", "unit_price", "line_amount", "item_amount", "personal_account_amount",
    ]

    /// 独立于提示词的输出校验：错行、凭空编造、数字子串、删除否定均不得进入确认卡。
    public static func fields(_ candidates: [OCRExtractedSpan], lines: [String]) -> [FieldDraft] {
        var seen = Set<String>()
        return candidates.prefix(128).compactMap { item in
            guard allowedKeys.contains(item.key), lines.indices.contains(item.lineIndex) else { return nil }
            let line = lines[item.lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 2048, let range = line.range(of: value) else { return nil }
            if narrativeKeys.contains(item.key), value != line, value != labeledValue(line) { return nil }
            if numericKeys.contains(item.key) || value.first?.isNumber == true || value.last?.isNumber == true {
                let boundaries = CharacterSet(charactersIn: "0123456789.,+-−<>≤≥")
                if (numericKeys.contains(item.key) || value.first?.isNumber == true), range.lowerBound > line.startIndex,
                   line[line.index(before: range.lowerBound)].unicodeScalars.contains(where: boundaries.contains) { return nil }
                if (numericKeys.contains(item.key) || value.last?.isNumber == true), range.upperBound < line.endIndex,
                   line[range.upperBound].unicodeScalars.contains(where: boundaries.contains) { return nil }
            }
            if ["drug_name", "generic_name"].contains(item.key),
               ["禁用", "停用", "不要", "不服用", "未服", "勿服", "过敏", "過敏", "allergic", "allergy", "avoid", "do not", "not take", "never", "discontinue", "stop taking"].contains(where: { line.localizedCaseInsensitiveContains($0) }) { return nil }
            let unit = item.unit?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard unit == nil || unit?.isEmpty == true || line.contains(unit ?? "") else { return nil }
            if let unit, !unit.isEmpty, let unitRange = line.range(of: unit) {
                let unitLetters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZμµ/^%0123456789")
                if unitRange.lowerBound > line.startIndex {
                    let before = line[line.index(before: unitRange.lowerBound)]
                    if before.isLetter && before.unicodeScalars.allSatisfy({ $0.value < 128 || $0.value == 181 || $0.value == 956 }) { return nil }
                }
                if unitRange.upperBound < line.endIndex, line[unitRange.upperBound].unicodeScalars.contains(where: unitLetters.contains) { return nil }
            }
            let identity = "\(item.lineIndex)|\(item.key)|\(value)"
            guard seen.insert(identity).inserted else { return nil }
            return FieldDraft(key: item.key, value: normalized(value, key: item.key), unit: unit?.isEmpty == true ? nil : unit,
                confidence: 0.6, rawText: line, source: .foundationModels, sourceLineIndex: item.lineIndex)
        }
    }

    public static func normalized(_ value: String, key: String) -> String {
        if key == "currency", ["人民币", "人民幣", "RMB"].contains(value) { return "CNY" }
        if key == "item_type" {
            switch value { case "发票", "發票": return "invoice"; case "收费单", "收費單", "费用", "費用": return "fee"; case "收据", "收據": return "receipt"; default: break }
        }
        if key == "unit_kind" {
            switch value { case "片": return "tablet"; case "粒", "胶囊", "膠囊": return "capsule"; case "贴", "貼": return "patch"; case "支", "瓶": return "vial"; default: break }
        }
        if key == "prescription_type" {
            // 处方笺印刷类型标签 → canonical raw（prescription.prescription_type CHECK；展示经 fieldValueDisplay）。词表归一，非推断。
            switch value {
            case "普通", "普通处方", "普通處方": return "general"
            case "急诊", "急診", "急诊处方", "急診處方": return "emergency"
            case "儿科", "兒科", "儿科处方", "兒科處方": return "pediatric"
            case "麻醉", "麻醉药品", "麻醉藥品", "麻醉处方", "麻醉處方": return "narcotic"
            case "精神", "精神药品", "精神藥品", "精一", "精二", "第一类精神药品", "第二类精神药品": return "psychotropic"
            case "中药", "中藥", "中草药", "中草藥", "中药饮片", "中藥飲片", "中药处方", "中藥處方": return "tcm"
            default: break
            }
        }
        return value
    }

    private static func labeledValue(_ line: String) -> String {
        guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return line }
        let label = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        // Only an explicit field label can be removed; arbitrary colon-delimited instructions cannot.
        let labels: Set<String> = [
            "诊断", "診斷", "初步诊断", "初步診斷", "主诉", "主訴", "医嘱", "醫囑", "处理", "處理", "摘要", "Diagnosis", "Instructions", "Summary",
            // v25 叙事列标签（简/繁/英）：现病史 / 病情说明 / 就诊总结 / 既往史 / 体格检查 / 过敏史 / 贮藏 / 注意事项
            "现病史", "現病史", "Present Illness", "History of Present Illness", "HPI",
            "病情说明", "病情說明", "病情", "Illness Summary", "Condition",
            "就诊总结", "就診總結", "就诊小结", "就診小結", "Visit Summary",
            "既往史", "既往病史", "Past History", "Past Medical History", "PMH",
            "体格检查", "體格檢查", "查体", "查體", "Physical Exam", "Physical Examination",
            "过敏史", "過敏史", "药物过敏史", "藥物過敏史", "Allergy History", "Allergies",
            "贮藏", "貯藏", "储藏", "儲藏", "Storage",
            "注意事项", "注意事項", "用药注意事项", "用藥注意事項", "Precautions", "Warnings",
            "临床诊断", "臨床診斷", "Clinical Diagnosis",
        ]
        guard labels.contains(label) else { return line }
        return String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }
}
