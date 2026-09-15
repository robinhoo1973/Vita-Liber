import Foundation

/// FR17.18 信息卡分组路由（ui-ux 4.28 OcrFieldGroupCard）：字段键 → 类别键
/// （rx=药品信息 / lab=检查结果 / visit=就诊信息 / generic=未分类）。
/// 稳定键单一事实源——App 层按类别键映射 L10n 卡头标签，键语义漂移只维护此处。
/// 结构轮（2026-09-15）：自 DocumentTypeClassifierFallback.swift 迁出（P2）。
public enum FieldGroupRules {
    public static func category(ofKey key: String) -> String {
        if key.hasPrefix("rx_") { return "rx" }
        if key.hasPrefix("lab_") || key == "dept" || key == "report_date"
            || key == "reference_range" { return "lab" }
        if ["chief_complaint", "diagnosis", "treatment"].contains(key) { return "visit" }
        return "generic"
    }

    /// 信息卡呈现顺序（卡序按类别固定；卡内字段按确认集原序）
    public static let categoryOrder: [String] = ["rx", "lab", "visit", "generic"]
}
