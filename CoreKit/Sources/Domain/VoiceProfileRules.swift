import Foundation

/// FR17.11 语音档案字段归一（纯函数，BR-003：只做格式归一，不做医学推断）。
///
/// 语音确认卡仍逐字段可编辑；本类型只把「用户口语 → 结构化字段」的机械差异
/// 收敛到一处：血型大小写/阴阳性写法、中文出生日期、证件/医保号空白。
/// 无法可靠归一的值返回 nil，由调用方保留原文（确认卡复核），绝不猜测。
public enum VoiceProfileRules {
    /// 档案字段归一入口；nil = 非本规则负责的字段或无法可靠归一。
    public static func normalizedValue(key: String, value: String) -> String? {
        switch key {
        case "bloodType": return bloodType(from: value)
        case "birthDate": return birthDate(from: value)
        case "idNo", "insuranceNo": return trimmed(value)
        default: return nil
        }
    }

    /// 口语血型 → 既有血型归一器（`ProfileSuggestion.normalizedBloodType`，检验导入同源）。
    /// 只说字母（无 Rh 阴阳性）时返回字母本身（病历允许未知 Rh 的自由文本）；
    /// 未完整消费（如「ABO型」「阳性」单独出现）返回 nil，由确认卡保留原文复核。
    public static func bloodType(from value: String) -> String? {
        ProfileSuggestionExtractor.normalizedBloodType(value, labelMentionsRh: false)
    }

    /// 口语出生日期 → `yyyy-MM-dd`（仅当年月日都可靠且通过 Domain 合法性校验）。
    /// 文法**委托** `ExtractionPatterns.dateMatch`（全仓日期单文法：全角数字、
    /// OCR 混淆字、2 位年、紧凑 8 位），本处只补档案生日区间/伪日期判据。
    public static func birthDate(from value: String) -> String? {
        guard let match = ExtractionPatterns.dateMatch(in: value) else { return nil }
        let formatted = String(format: "%04d-%02d-%02d", match.year, match.month, match.day)
        // 与成员档案同一合法性判据（拒绝 2 月 30 日等伪日期、未来日期）。
        return MemberProfileCompleteness.isValidBirthDate(formatted) ? formatted : nil
    }

    private static func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
