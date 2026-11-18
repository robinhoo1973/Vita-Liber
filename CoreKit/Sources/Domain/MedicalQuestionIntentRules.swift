import Foundation

/// 说明书检索前的意图闸门（BR-006）：只有「原文怎么写的」可以引用，
/// 个人化剂量、停药换药、合用结论、选药比较一律拒答。
public enum MedicalQuestionIntent: String, Sendable, CaseIterable {
    case personalDosage
    case stopOrSwitch
    case interaction
    case comparison
    case none
}

public enum MedicalQuestionIntentRules {
    private static let dosage = ["吃几片", "吃多少", "吃几次", "剂量是多少", "加量", "减量",
                                 "加大剂量", "减少剂量", "一天吃", "一次吃"]
    private static let stopSwitch = ["停药", "换药", "可以停", "能停", "换一种", "换成"]
    private static let interaction = ["一起吃", "合用", "同服", "相互作用", "冲突", "能一起"]
    private static let comparison = ["哪个好", "哪个药更", "哪个药好", "哪个更", "该吃哪个",
                                     "能替代", "替代吗", "换哪个", "更好"]

    /// 文本归一：全半角折叠 + 去空白 + 小写；只用于匹配。
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.widthInsensitive, .caseInsensitive],
                                  locale: Locale(identifier: "zh_Hans_CN"))
        return folded.filter { !$0.isWhitespace }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    /// 判定顺序：先放行「说明书原文怎么写」的查询，再按风险从高到低拒识。
    public static func classify(_ text: String) -> MedicalQuestionIntent {
        let value = normalize(text)
        guard !value.isEmpty else { return .none }
        let asksLeaflet = value.contains("说明书") || value.contains("原文")
        if asksLeaflet, value.contains("用法用量") || value.contains("剂量") {
            return .none
        }
        if containsAny(value, dosage) { return .personalDosage }
        if containsAny(value, stopSwitch) { return .stopOrSwitch }
        if containsAny(value, interaction) { return .interaction }
        if containsAny(value, comparison) { return .comparison }
        return .none
    }
}
