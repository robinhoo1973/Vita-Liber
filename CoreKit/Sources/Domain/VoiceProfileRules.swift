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
    /// 关键边界：`片/粒/胶囊` 既可能是剂型后缀也可能是药名的一部分
    /// （「阿司匹林肠溶片」）——只删除**带数量词**的剂量片段，不再全局删剂型字。
    public static func medicationNames(from value: String) -> [String] {
        let separators = CharacterSet(charactersIn: "、,，;；\n")
        let noise = ["每天", "每日", "一日", "两次", "三次", "一次", "口服", "饭后", "饭前",
                     "早上", "晚上", "中午", "服用", "吃", "还有", "以及", "和"]
        let dosePattern = #"[0-9０-９一二三四五六七八九十半.]+\s*(?:毫克|mg|克|g|毫升|ml|单位|iu)"#
        let doseRegex: NSRegularExpression?
        do { doseRegex = try NSRegularExpression(pattern: dosePattern, options: [.caseInsensitive]) }
        catch { doseRegex = nil }
        var seen = Set<String>()
        return value.components(separatedBy: separators).compactMap { raw in
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if let doseRegex {
                text = doseRegex.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
            }
            for word in noise { text = text.replacingOccurrences(of: word, with: " ") }
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

    /// 家属关系口语 → 新建成员可选关系（`MemberRelation.creatable`）。
    /// 只做确定性同义词映射；没有命中任何关系词时返回 nil，由确认卡让用户重说，
    /// 不把「其他」当成听懂了（新建成员关系属于用户明确陈述，不猜）。
    public static func relation(from value: String) -> MemberRelation? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let aliases: [(MemberRelation, [String])] = [
            (.partner, ["配偶", "丈夫", "妻子", "老公", "老婆", "爱人"]),
            (.child, ["子女", "儿子", "女儿", "孩子"]),
            (.parent, ["父母", "父亲", "母亲", "爸爸", "妈妈"]),
            (.grandparent, ["祖父母", "爷爷", "奶奶", "外公", "外婆"]),
        ]
        for (relation, words) in aliases where words.contains(where: text.contains) {
            return relation
        }
        if text.contains("朋友") || text.contains("同事") || text == "其他" {
            return .other
        }
        return nil
    }

    /// 新建家属的一句话草稿（名称 / 关系 / 生日）。只做确定性剥离：
    /// 关系词与日期文法都来自既有单一来源，剩余字母串才视为姓名；
    /// 任一项没听清就留空，由新建表单让用户补，不猜。
    public struct MemberDraft: Sendable, Equatable {
        public var name: String?
        public var relation: MemberRelation?
        public var birthDate: String?
        public init(name: String?, relation: MemberRelation?, birthDate: String?) {
            self.name = name
            self.relation = relation
            self.birthDate = birthDate
        }
    }

    public static func memberDraft(from value: String) -> MemberDraft {
        let relation = relation(from: value)
        let birthDate = birthDate(from: value)
        var remainder = value
        if let match = ExtractionPatterns.dateMatch(in: value) {
            remainder.removeSubrange(match.range)
        }
        let relationWords = ["配偶", "丈夫", "妻子", "老公", "老婆", "爱人",
                             "子女", "儿子", "女儿", "孩子", "父母", "父亲", "母亲",
                             "爸爸", "妈妈", "祖父母", "爷爷", "奶奶", "外公", "外婆",
                             "朋友", "同事", "其他"]
        for word in relationWords + ["我叫", "我是", "我的", "名字叫", "名称", "叫",
                                     "出生", "生日", "日期", "今年", "岁", "我", "她", "他"] {
            remainder = remainder.replacingOccurrences(of: word, with: " ")
        }
        let kept = remainder.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.whitespaces.contains($0)
        }
        let name = String(String.UnicodeScalarView(kept))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fillers: Set<String> = ["嗯", "啊", "哦", "呃", "唉", "没有", "不知道", "无"]
        return MemberDraft(name: (1...12).contains(name.count) && !fillers.contains(name) ? name : nil,
                           relation: relation,
                           birthDate: birthDate)
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
