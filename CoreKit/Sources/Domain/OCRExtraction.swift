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
    public static let allowedKeys: Set<String> = [
        "hospital", "doctor", "dept", "report_date", "prescribed_at", "chief_complaint",
        "diagnosis", "treatment", "present_illness", "illness_summary", "visit_summary",
        "lab_item", "reference_range", "drug_name", "advice_text", "generic_name", "brand_name",
        "spec", "unit_kind", "dosage", "quantity", "frequency", "route", "days", "note",
        "amount", "currency", "item_type", "merchant", "summary", "vaccine_name",
        "dose_number", "administered_at", "provider", "lot_number", "reimbursed_amount", "out_of_pocket",
    ]
    public static let documentTypes: Set<String> = [
        "prescription", "lab_report", "outpatient_record", "diagnosis_certificate", "vaccine_record", "invoice", "medication_label",
    ]
    private static let narrativeKeys: Set<String> = [
        "diagnosis", "chief_complaint", "treatment", "advice_text", "summary",
        "present_illness", "illness_summary", "visit_summary"
    ]
    private static let numericKeys: Set<String> = ["amount", "dose_number", "quantity", "days", "reimbursed_amount", "out_of_pocket"]

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
        return value
    }

    private static func labeledValue(_ line: String) -> String {
        guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return line }
        let label = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        // Only an explicit field label can be removed; arbitrary colon-delimited instructions cannot.
        let labels: Set<String> = ["诊断", "診斷", "初步诊断", "初步診斷", "主诉", "主訴", "医嘱", "醫囑", "处理", "處理", "摘要", "Diagnosis", "Instructions", "Summary"]
        guard labels.contains(label) else { return line }
        return String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }
}
