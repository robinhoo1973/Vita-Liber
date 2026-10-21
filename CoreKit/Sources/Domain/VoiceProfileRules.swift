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

    /// 过敏口语 → 结构化条目（仅确定性切分/词表映射，不推断严重度以外诊断）。
    public struct AllergyEntry: Sendable, Equatable {
        public var substance: String
        public var severity: String       // 轻/中/重
        public var reactionTags: [String]
        public init(substance: String, severity: String, reactionTags: [String]) {
            self.substance = substance; self.severity = severity; self.reactionTags = reactionTags
        }
    }

    public static func allergies(from value: String) -> [AllergyEntry] {
        let separators = CharacterSet(charactersIn: "、,，;；\n")
        var result: [AllergyEntry] = []
        for raw in value.components(separatedBy: separators) {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.contains("无过敏"), !text.contains("没有过敏") else { continue }
            let severity: String
            if text.contains("重") || text.contains("休克") { severity = "重" }
            else if text.contains("中") { severity = "中" }
            else { severity = "轻" }
            let tags = SevereReactionRules.reactionTagOptions.filter { text.contains($0) }
            var substance = text
            for tag in tags { substance = substance.replacingOccurrences(of: tag, with: "") }
            for word in ["过敏", "反应", "对", "有", "轻度", "中度", "重度", "严重"] {
                substance = substance.replacingOccurrences(of: word, with: "")
            }
            substance = substance.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !substance.isEmpty, substance != "无", substance != "没有" else { continue }
            result.append(AllergyEntry(substance: substance, severity: severity, reactionTags: tags))
        }
        return result
    }

    /// 既往史口语 → 健康问题名（只做分句与机械清洗，不推断诊断）。
    public static func healthProblemNames(from value: String) -> [String] {
        let separators = CharacterSet(charactersIn: "、,，;；\n")
        var seen = Set<String>()
        return value.components(separatedBy: separators).compactMap { raw in
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.contains("无"), !text.contains("没有") else { return nil }
            for word in ["既往史", "病史", "曾经", "患有", "患过", "有过", "有", "患"] {
                text = text.replacingOccurrences(of: word, with: "")
            }
            text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            guard !text.isEmpty, seen.insert(text).inserted else { return nil }
            return text
        }
    }

    /// 当前用药口语 → 药名（只做分句与剂量词清洗；剂量/频次仍留给用药页复核）。
    public static func medicationNames(from value: String) -> [String] {
        let separators = CharacterSet(charactersIn: "、,，;；\n")
        let noise = ["每天", "每日", "一日", "两次", "三次", "一次", "口服", "饭后", "饭前",
                     "早上", "晚上", "中午", "毫克", "mg", "片", "粒", "胶囊", "注射"]
        var seen = Set<String>()
        return value.components(separatedBy: separators).compactMap { raw in
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            for word in noise { text = text.replacingOccurrences(of: word, with: "") }
            text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            guard !text.isEmpty, seen.insert(text).inserted else { return nil }
            return text
        }
    }

    /// 紧急联系人口语 → 结构化联系人；没有可校验手机号时不落结构化表。
    public static func emergencyContact(from value: String) -> EmergencyContactDraft? {
        let pattern = #"[+]?[0-9][0-9+\- ()]{4,}"#
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: pattern) } catch { return nil }
        guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else { return nil }
        let phone = String(value[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard EmergencyContactDraft.validPhone(phone) else { return nil }
        var prefix = String(value[..<range.lowerBound])
        let relationAliases: [(String, String)] = [
            ("丈夫", "配偶"), ("妻子", "配偶"), ("爱人", "配偶"),
            ("儿子", "子女"), ("女儿", "子女"),
            ("爸爸", "父母"), ("妈妈", "父母"), ("父亲", "父母"), ("母亲", "父母"),
            ("爷爷", "祖父母"), ("奶奶", "祖父母"),
        ]
        var relation = "其他"
        for (alias, canonical) in relationAliases where prefix.contains(alias) {
            relation = canonical
            prefix = prefix.replacingOccurrences(of: alias, with: "")
            break
        }
        if relation == "其他" {
            let relationValues = MemberRelation.creatable.map(\.rawValue)
            if let found = relationValues.first(where: { prefix.contains($0) }) {
                relation = found
                prefix = prefix.replacingOccurrences(of: found, with: "")
            }
        }
        for word in ["紧急联系人", "联系人", "电话", "手机", "：", ":"] {
            prefix = prefix.replacingOccurrences(of: word, with: "")
        }
        let name = prefix.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !name.isEmpty else { return nil }
        return EmergencyContactDraft(name: name, relation: relation, phone: phone)
    }

    /// 访谈分段写回：替换同节旧行，避免重复进入访谈时在档案备注追加
    /// 第二段/第三段同节内容（FR17.11 可中断续填）。
    public static func upsertingSection(in note: String?, section: String,
                                        value: String) -> String {
        let marker = "【\(section)】"
        var lines = (note ?? "").components(separatedBy: "\n")
            .filter { !$0.hasPrefix(marker) && !$0.isEmpty }
        lines.append(marker + value)
        return lines.joined(separator: "\n")
    }

    private static func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
