import Foundation

/// FR23.3 严重反应判定（Domain 纯函数）：
/// 标记为「重度」或命中关键词（呼吸困难/喉头水肿/意识不清/过敏性休克等）→
/// 保存后立即展示急救引导卡（就近就医/拨打 120，BR-012）。
/// 不做任何诊断表述、不阻塞保存——App 只如实记录用户自述事实。
public enum SevereReactionRules {
    /// 第八轮全仓审查修复（关键词单一事实源）：严重反应词表与 F12 紧急
    /// 词表（EmergencyKeywordRules，BR-012 单一事实源）此前各自维护一份
    /// 重叠漂移集——新增关键词只进一份，另一路径静默漏触发。改为
    /// 「F12 基础表 + 过敏专属补充」复合（过敏性休克/英文同义词不在
    /// F12 内，属过敏领域补充）。
    public static let severeKeywords: [String] = [
        "过敏性休克", "anaphylaxis", "anaphylactic",
        "breathing difficulty", "throat swelling",
    ] + EmergencyKeywordRules.keywords

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

    /// 严重度等级（升序：0=mild/轻，1=moderate/中，2=severe/重；未知返回
    /// nil）——视图配色/排序的单一事实源（第八轮全仓审查修复：视图此前
    /// 内联 `severityValues[2] || "severe"` 魔法字符串，与 DDL CHECK 词
    /// 汇表（mild/moderate/severe）双源漂移——任一改动即漏配一处）。
    /// 展示词与规范值都经 canonicalSeverity 归一后判定。
    public static func severityLevel(of displayOrCanonical: String) -> Int? {
        switch canonicalSeverity(displayOrCanonical) {
        case "mild": return 0
        case "moderate": return 1
        case "severe": return 2
        default: return nil
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
