import Foundation

/// FR6.9 / FR5.5：根据识别内容（OCR 实体卡/字段集）自动为医疗文档生成标准化命名建议。
///
/// 命名格式：`[日期 · ][医疗机构 · ]类型名称[ · 科室]`
/// 例如：
/// - `2026-09-12 · 北京协和医院 · 门诊病历 · 呼吸内科`
/// - `2026-09-12 · 中日友好医院 · 处方笺`
/// - `2026-09-12 · 检验报告单`
/// 纯函数、Domain 零框架依赖。
public enum DocumentNaming {
    public static func suggestTitle(fields: [FieldDraft], documentType: String?) -> String? {
        let dict = dictionary(fields)
        let date = dict["report_date"] ?? dict["prescribed_at"] ?? dict["measured_at"] ?? dict["date"] ?? dict["administered_at"]
        let hospital = dict["hospital"] ?? dict["merchant"] ?? dict["provider"]
        let dept = dict["dept"] ?? dict["department"]
        // documentType 是卡类型（MatchedCard.kind）而非文档类型键（outpatient_record 等）——
        // 先按文档类型键取名称，未命中（encounter/metric_sample/claim_item/…）回落卡类型名。
        let typeName = displayName(forDocType: documentType) ?? documentType.flatMap { displayName(forKind: $0) }

        var components: [String] = []
        if let date, !date.isEmpty { components.append(date) }
        if let hospital, !hospital.isEmpty { components.append(hospital) }
        if let typeName, !typeName.isEmpty {
            if let dept, !dept.isEmpty {
                components.append("\(typeName) · \(dept)")
            } else {
                components.append(typeName)
            }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: " · ")
    }

    private static func displayName(forKind kind: String) -> String {
        switch kind {
        case "prescription": return "处方笺"
        case "encounter": return "门诊病历"
        case "metric_sample": return "检验报告"
        case "medication": return "药品说明"
        case "claim_item": return "收费票据"
        case "immunization": return "接种凭证"
        default: return ""
        }
    }

    private static func displayName(forDocType type: String?) -> String? {
        guard let type else { return nil }
        switch type {
        case "prescription": return "处方笺"
        case "outpatient_record", "diagnosis_certificate": return "门诊病历"
        case "lab_report": return "检验报告"
        case "medication_label": return "药品标签"
        case "invoice": return "收费票据"
        case "vaccine_record": return "接种记录"
        default: return nil
        }
    }

    private static func dictionary(_ fields: [FieldDraft]) -> [String: String] {
        Dictionary(fields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}
