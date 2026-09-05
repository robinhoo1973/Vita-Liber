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

    /// 严重度展示词 → 落库规范值（SchemaV2 CHECK：mild/moderate/severe）。
    /// 审查修复：UI 用中文三档，DDL 只接受英文枚举——此前原样 INSERT 直接
    /// 违反 CHECK 约束，每一次过敏保存都静默失败（GRDB 抛错被上层吞掉）。
    /// 规范值/未知值原样透传（历史行与测试直写兼容）。
    public static func canonicalSeverity(_ display: String) -> String {
        switch display {
        case "轻": return "mild"
        case "中": return "moderate"
        case "重": return "severe"
        default: return display
        }
    }

    /// 落库规范值 → 展示词（列表回显反向映射；未知值透传）
    public static func displaySeverity(_ canonical: String) -> String {
        switch canonical {
        case "mild": return "轻"
        case "moderate": return "中"
        case "severe": return "重"
        default: return canonical
        }
    }
}
