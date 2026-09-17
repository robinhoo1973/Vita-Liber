import Foundation

/// 检测/检查项的分类（业主 2026-09-17 定：酶类检测与检查项配象征图标——
/// 检验报告数值/定性行、体检子报告等逐项呈现时按名称分类，符号映射在
/// App 层 `CardKindIcon`（图标单一出口，§3.4 纪律）。纯规则零 IO。
public enum LabItemKind: String, Sendable, Equatable {
    /// 酶类检测（转氨酶/磷酸酶/淀粉酶/肌酸激酶等——中文检验项目惯例以「酶」结尾）。
    case enzyme
    /// 检查项（影像/功能检查类，如超声/X光/CT/内镜/心电）。
    case exam
    /// 其余检验项（默认）。
    case routine
}

public enum LabItemRules {
    /// 检查项关键词（命中即 exam；先判酶类再判检查项——「心肌酶谱」归酶类）。
    /// 内镜族逐类列名（胃镜/肠镜/喉镜/支气管镜）——不用裸「镜」：尿常规里的
    /// 「镜检」（显微镜检查）是检验项，会被误分类。
    public static let examKeywords = [
        "超声", "彩超", "B超", "X光", "X线", "CT", "磁共振", "MRI",
        "内镜", "胃镜", "肠镜", "喉镜", "支气管镜", "造影", "心电", "脑电",
        "肺功能", "骨密度"
    ]

    /// 名称分类：酶类 > 检查项 > 常规检验。
    public static func classify(label: String) -> LabItemKind {
        if label.contains("酶") { return .enzyme }
        if examKeywords.contains(where: { label.contains($0) }) { return .exam }
        return .routine
    }
}
