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
    /// S-6①（第九轮审查权重重判，`PDFExportService.kindLabel` 注入先例）：
    /// Domain 不持用户可见文案——类型名经闭包注入（App 装配注入 L10n 映射）；
    /// 未注入回落内置兜底（保持既有行为，绝不产出空标题）。typeName 落库进
    /// `document_file.title` 并原样上屏（列表/时间轴/医生展示/PDF），
    /// 此前 zh-Hant/en 用户在标题里读到简体「处方笺」。
    public struct Labels: Sendable {
        public var forKind: @Sendable (String) -> String          // 卡类 kind → 名称（无映射返回空串）
        public var forDocType: @Sendable (String) -> String?      // 文档类型键 → 名称（未登记 nil）
        public init(forKind: @escaping @Sendable (String) -> String,
                    forDocType: @escaping @Sendable (String) -> String?) {
            self.forKind = forKind
            self.forDocType = forDocType
        }
        public static let builtin = Labels(forKind: { kind in
            switch kind {
            case "prescription": return "处方笺"
            case "encounter": return "门诊病历"
            case "metric_sample": return "检验报告"
            case "medication": return "药品说明"
            case "claim_item": return "收费票据"
            case "immunization": return "接种凭证"
            default: return ""
            }
        }, forDocType: { type in
            switch type {
            case "prescription": return "处方笺"
            case "outpatient_record", "diagnosis_certificate": return "门诊病历"
            case "lab_report": return "检验报告"
            case "medication_label": return "药品标签"
            case "invoice": return "收费票据"
            case "vaccine_record": return "接种记录"
            default: return nil
            }
        })
    }

    public static func suggestTitle(fields: [FieldDraft], documentType: String?,
                                    labels: Labels = .builtin) -> String? {
        let dict = dictionary(fields)
        let date = dict["report_date"] ?? dict["prescribed_at"] ?? dict["measured_at"] ?? dict["date"] ?? dict["administered_at"]
        let hospital = dict["hospital"] ?? dict["merchant"] ?? dict["provider"]
        let dept = dict["dept"] ?? dict["department"]
        // documentType 是卡类型（MatchedCard.kind）而非文档类型键（outpatient_record 等）——
        // 先按文档类型键取名称，未命中（encounter/metric_sample/claim_item/…）回落卡类型名。
        let typeName = documentType.flatMap { labels.forDocType($0) }
            ?? documentType.flatMap { labels.forKind($0) }.flatMap { $0.isEmpty ? nil : $0 }

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
        Labels.builtin.forKind(kind)
    }

    private static func displayName(forDocType type: String?) -> String? {
        type.flatMap { Labels.builtin.forDocType($0) }
    }

    private static func dictionary(_ fields: [FieldDraft]) -> [String: String] {
        Dictionary(fields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}
