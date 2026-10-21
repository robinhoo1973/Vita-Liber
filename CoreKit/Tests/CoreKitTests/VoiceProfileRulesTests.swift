import Foundation
import Testing
@testable import Domain

/// FR17.11 语音档案归一：只做格式归一，不做医学推断（BR-003）。
/// 血型复用检验导入同一归一器；生日复用全仓日期单文法。
struct VoiceProfileRulesTests {

    @Test func bloodTypeReusesLabNormalizer() {
        #expect(VoiceProfileRules.bloodType(from: "A型阳性") == "A Rh+")
        #expect(VoiceProfileRules.bloodType(from: "AB阴性") == "AB Rh-")
        #expect(VoiceProfileRules.bloodType(from: "B+") == "B Rh+")
        #expect(VoiceProfileRules.bloodType(from: "0型") == "O")   // 数字 0 = O 型
        #expect(VoiceProfileRules.bloodType(from: "O") == "O")
    }

    @Test func bloodTypeRejectsAmbiguousSpeech() {
        #expect(VoiceProfileRules.bloodType(from: "ABO型") == nil)   // 不把 ABO 整体当 AB
        #expect(VoiceProfileRules.bloodType(from: "阳性") == nil)    // 单独 Rh 不是完整血型
        #expect(VoiceProfileRules.bloodType(from: "不知道") == nil)
    }

    @Test func birthDateUsesSharedGrammar() {
        #expect(VoiceProfileRules.birthDate(from: "1990年5月3日") == "1990-05-03")
        #expect(VoiceProfileRules.birthDate(from: "1990/5/3") == "1990-05-03")
        #expect(VoiceProfileRules.birthDate(from: "19900503") == "1990-05-03")
        #expect(VoiceProfileRules.birthDate(from: "１９９０－０５－０３") == "1990-05-03")
    }

    @Test func birthDateRejectsInvalidOrFuture() {
        #expect(VoiceProfileRules.birthDate(from: "2023-02-30") == nil)
        #expect(VoiceProfileRules.birthDate(from: "2999-01-01") == nil)
        #expect(VoiceProfileRules.birthDate(from: "不知道") == nil)
    }

    @Test func sectionUpsertReplacesInsteadOfAppending() {
        let first = VoiceProfileRules.upsertingSection(in: nil, section: "过敏", value: "青霉素")
        let second = VoiceProfileRules.upsertingSection(in: first, section: "过敏", value: "青霉素、花生")
        #expect(second == "【过敏】青霉素、花生")
        let mixed = VoiceProfileRules.upsertingSection(in: second, section: "既往史", value: "高血压")
        #expect(mixed == "【过敏】青霉素、花生\n【既往史】高血压")
    }

    @Test func structuredParsersAreConservative() {
        let allergies = VoiceProfileRules.allergies(from: "青霉素过敏、花生")
        #expect(allergies.count == 2)
        #expect(allergies[0].substance == "青霉素")
        #expect(allergies[0].severity == "轻")
        #expect(VoiceProfileRules.allergies(from: "无过敏").isEmpty)
        #expect(VoiceProfileRules.healthProblemNames(from: "既往史：高血压、糖尿病") == ["高血压", "糖尿病"])
        let contact = VoiceProfileRules.emergencyContact(from: "女儿 张三 13800138000")
        #expect(contact?.name == "张三")
        #expect(contact?.relation == "子女")
        #expect(contact?.phone == "13800138000")
        #expect(VoiceProfileRules.emergencyContact(from: "没有电话") == nil)
        #expect(VoiceProfileRules.medicationNames(from: "二甲双胍 每天两次、阿司匹林") == ["二甲双胍", "阿司匹林"])
        // 剂型字只在带数量时删除；药名后缀必须保留（真实药名常以片/胶囊结尾）。
        #expect(VoiceProfileRules.medicationNames(from: "阿司匹林肠溶片 100mg 每天一次、二甲双胍 0.5 克")
                == ["阿司匹林肠溶片", "二甲双胍"])
        #expect(VoiceProfileRules.medicationNames(from: "胰岛素注射液") == ["胰岛素注射液"])
        #expect(VoiceProfileRules.medicationNames(from: "维生素B12 片") == ["维生素B12 片"])
    }

    @Test func relationMapsOnlyKnownWords() {
        #expect(VoiceProfileRules.relation(from: "我女儿") == .child)
        #expect(VoiceProfileRules.relation(from: "爱人") == .partner)
        #expect(VoiceProfileRules.relation(from: "母亲") == .parent)
        #expect(VoiceProfileRules.relation(from: "外婆") == .grandparent)
        #expect(VoiceProfileRules.relation(from: "朋友") == .other)
        #expect(VoiceProfileRules.relation(from: "嗯") == nil)
        #expect(VoiceProfileRules.relation(from: "  ") == nil)
    }

    @Test func memberDraftSplitsNameRelationAndBirthDate() {
        let full = VoiceProfileRules.memberDraft(from: "我女儿张敏，1990年5月3日出生")
        #expect(full.name == "张敏")
        #expect(full.relation == .child)
        #expect(full.birthDate == "1990-05-03")
        let nameOnly = VoiceProfileRules.memberDraft(from: "张三")
        #expect(nameOnly.name == "张三")
        #expect(nameOnly.relation == nil)
        let relationOnly = VoiceProfileRules.memberDraft(from: "妈妈")
        #expect(relationOnly.name == nil)
        #expect(relationOnly.relation == .parent)
        #expect(VoiceProfileRules.memberDraft(from: "嗯").name == nil)
    }

    @Test func identifierFieldsTrimOnly() {
        #expect(VoiceProfileRules.normalizedValue(key: "idNo", value: "  110101199001011234 ") == "110101199001011234")
        #expect(VoiceProfileRules.normalizedValue(key: "insuranceNo", value: "   ") == nil)
        #expect(VoiceProfileRules.normalizedValue(key: "note", value: "x") == nil)
    }
}
