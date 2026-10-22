import Foundation

/// FR3.7 新建家属的一句话草稿规则（纯函数，BR-003：只做格式归一，不做医学推断）。
///
/// 语音引导档案流程已退役（2026-10-22）；本类型只服务「添加家人」表单的
/// 姓名/关系/生日拆分，不承接过敏、病史、用药等健康档案内容。
public enum MemberDraftRules {
    /// 新建家属的一句话草稿（名称 / 关系 / 生日）。
    public struct MemberDraft: Sendable, Equatable {
        public var name: String?
        public var relation: MemberRelation?
        public var birthDate: String?
        public init(name: String?, relation: MemberRelation?, birthDate: String?) {
            self.name = name; self.relation = relation; self.birthDate = birthDate
        }
    }

    /// 家属关系口语 → 新建成员可选关系（`MemberRelation.creatable`）。
    /// 没有命中任何关系词时返回 nil，由表单让用户重说/手选，不把「其他」当成听懂了。
    public static func relation(from value: String) -> MemberRelation? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let aliases: [(MemberRelation, [String])] = [
            (.partner, ["配偶", "丈夫", "妻子", "老公", "老婆", "爱人", "老伴"]),
            (.child, ["子女", "儿子", "女儿", "孩子", "闺女"]),
            (.parent, ["父母", "父亲", "母亲", "爸爸", "妈妈", "老爸", "老妈"]),
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

    /// 口语出生日期 → `yyyy-MM-dd`（仅当年月日都可靠且通过 Domain 合法性校验）。
    /// 文法委托 `ExtractionPatterns.dateMatch`（全仓日期单文法）。
    public static func birthDate(from value: String) -> String? {
        guard let match = ExtractionPatterns.dateMatch(in: value) else { return nil }
        let formatted = String(format: "%04d-%02d-%02d", match.year, match.month, match.day)
        return MemberProfileCompleteness.isValidBirthDate(formatted) ? formatted : nil
    }

    /// 一句话草稿：关系词与日期文法来自单一来源，剩余字母串才视为姓名；
    /// 任一项没听清就留空，由新建表单让用户补，不猜。
    public static func memberDraft(from value: String) -> MemberDraft {
        let relation = relation(from: value)
        let birthDate = birthDate(from: value)
        var remainder = value
        if let match = ExtractionPatterns.dateMatch(in: value) {
            remainder.removeSubrange(match.range)
        }
        let relationWords = ["配偶", "丈夫", "妻子", "老公", "老婆", "爱人", "老伴",
                             "子女", "儿子", "女儿", "孩子", "闺女",
                             "父母", "父亲", "母亲", "爸爸", "妈妈", "老爸", "老妈",
                             "祖父母", "爷爷", "奶奶", "外公", "外婆",
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
}
