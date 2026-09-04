import Foundation

/// FR23.3 严重反应判定（Domain 纯函数）：
/// 标记为「重度」或命中关键词（呼吸困难/喉头水肿/意识不清/过敏性休克等）→
/// 保存后立即展示急救引导卡（就近就医/拨打 120，BR-012）。
/// 不做任何诊断表述、不阻塞保存——App 只如实记录用户自述事实。
public enum SevereReactionRules {
    public static let severeKeywords: [String] = [
        "呼吸困难", "喉头水肿", "意识不清", "过敏性休克", "窒息",
        "anaphylaxis", "anaphylactic", "breathing difficulty", "throat swelling",
    ]

    /// 是否触发急救引导（重度 或 关键词命中）
    public static func triggersEmergencyCard(severity: String,
                                             reactionTags: [String],
                                             note: String? = nil) -> Bool {
        if severity == "重" || severity == "severe" { return true }
        let corpus = (reactionTags + [note ?? ""]).joined(separator: " ")
        return severeKeywords.contains { corpus.localizedCaseInsensitiveContains($0) }
    }

    // FR23.1 选项常量（数据词汇，落库原值；视图禁止内联中文——单一来源在 Domain）
    public static let allergenKinds = ["药品", "食物", "其他"]
    public static let severityValues = ["轻", "中", "重"]
    public static let reactionTagOptions = [
        "皮疹", "荨麻疹", "恶心呕吐", "腹泻", "呼吸困难",
        "喉头水肿", "过敏性休克", "其他",
    ]
}
