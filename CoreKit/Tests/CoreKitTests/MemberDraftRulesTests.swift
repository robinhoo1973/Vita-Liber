import Foundation
import Testing
@testable import Domain

/// FR3.7 添加家人一句话草稿：只拆姓名/关系/生日，不做健康档案推断。
struct MemberDraftRulesTests {
    @Test func birthDateUsesSharedGrammar() {
        #expect(MemberDraftRules.birthDate(from: "1990年5月3日") == "1990-05-03")
        #expect(MemberDraftRules.birthDate(from: "1990/5/3") == "1990-05-03")
        #expect(MemberDraftRules.birthDate(from: "19900503") == "1990-05-03")
        #expect(MemberDraftRules.birthDate(from: "１９９０－０５－０３") == "1990-05-03")
        #expect(MemberDraftRules.birthDate(from: "2023-02-30") == nil)
        #expect(MemberDraftRules.birthDate(from: "2999-01-01") == nil)
        #expect(MemberDraftRules.birthDate(from: "不知道") == nil)
    }

    @Test func relationMapsOnlyKnownWords() {
        #expect(MemberDraftRules.relation(from: "我女儿") == .child)
        #expect(MemberDraftRules.relation(from: "爱人") == .partner)
        #expect(MemberDraftRules.relation(from: "母亲") == .parent)
        #expect(MemberDraftRules.relation(from: "外婆") == .grandparent)
        #expect(MemberDraftRules.relation(from: "闺女") == .child)
        #expect(MemberDraftRules.relation(from: "老伴") == .partner)
        #expect(MemberDraftRules.relation(from: "老爸") == .parent)
        #expect(MemberDraftRules.relation(from: "朋友") == .other)
        #expect(MemberDraftRules.relation(from: "嗯") == nil)
        #expect(MemberDraftRules.relation(from: "  ") == nil)
    }

    @Test func memberDraftSplitsNameRelationAndBirthDate() {
        let full = MemberDraftRules.memberDraft(from: "我女儿张敏，1990年5月3日出生")
        #expect(full.name == "张敏")
        #expect(full.relation == .child)
        #expect(full.birthDate == "1990-05-03")
        let colloquial = MemberDraftRules.memberDraft(from: "我闺女张敏")
        #expect(colloquial.name == "张敏")
        #expect(colloquial.relation == .child)
        let nameOnly = MemberDraftRules.memberDraft(from: "张三")
        #expect(nameOnly.name == "张三")
        #expect(nameOnly.relation == nil)
        let relationOnly = MemberDraftRules.memberDraft(from: "妈妈")
        #expect(relationOnly.name == nil)
        #expect(relationOnly.relation == .parent)
        #expect(MemberDraftRules.memberDraft(from: "嗯").name == nil)
    }
}
