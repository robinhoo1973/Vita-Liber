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
        let switched = VoiceProfileRules.upsertingSection(
            in: "【过敏】青霉素", section: "過敏",
            aliases: VoiceProfileRules.sectionAliases(for: "allergy"), value: "青霉素、花生")
        #expect(switched == "【過敏】青霉素、花生")
    }

    @Test func structuredParsersAreConservative() {
        let allergies = VoiceProfileRules.allergies(from: "青霉素过敏、花生")
        #expect(allergies.count == 2)
        #expect(allergies[0].substance == "青霉素")
        #expect(allergies[0].severity == nil)   // 未说严重度不得默认「轻」
        #expect(VoiceProfileRules.allergies(from: "青霉素轻度过敏").first?.severity == "轻")
        #expect(VoiceProfileRules.allergies(from: "无过敏").isEmpty)
        #expect(VoiceProfileRules.allergies(from: "没有").isEmpty)
        #expect(VoiceProfileRules.allergies(from: "不知道").isEmpty)
        // 否定句中间夹字不得漏网；句首人称要剥离，但药名里的「对」必须保留。
        #expect(VoiceProfileRules.allergies(from: "我没有药物过敏").isEmpty)
        #expect(VoiceProfileRules.allergies(from: "我对花粉过敏，没有其他过敏").map(\.substance) == ["对花粉"])
        #expect(VoiceProfileRules.allergies(from: "我对乙酰氨基酚过敏").map(\.substance) == ["对乙酰氨基酚"])
        #expect(VoiceProfileRules.healthProblemNames(from: "既往史：高血压、糖尿病") == ["高血压", "糖尿病"])
        #expect(VoiceProfileRules.healthProblemNames(from: "无痛性血尿、无症状性菌尿")
                == ["无痛性血尿", "无症状性菌尿"])
        let contact = VoiceProfileRules.emergencyContact(from: "女儿 张三 13800138000")
        #expect(contact?.name == "张三")
        #expect(contact?.relation == "子女")
        #expect(contact?.phone == "13800138000")
        let spoken = VoiceProfileRules.emergencyContact(from: "我女儿张敏，手机号 138 0013 8000")
        #expect(spoken?.name == "张敏")
        #expect(spoken?.relation == "子女")
        #expect(spoken?.phone == "138 0013 8000")
        #expect(VoiceProfileRules.emergencyContact(from: "没有电话") == nil)
        let withDate = VoiceProfileRules.emergencyContact(
            from: "我女儿，2024-05-01 换的号，13800138000")
        #expect(withDate?.phone == "13800138000")
        #expect(VoiceProfileRules.medicationNames(from: "二甲双胍 每天两次、阿司匹林") == ["二甲双胍", "阿司匹林"])
        // 剂型字只在带数量时删除；药名后缀必须保留（真实药名常以片/胶囊结尾）。
        #expect(VoiceProfileRules.medicationNames(from: "阿司匹林肠溶片 100mg 每天一次、二甲双胍 0.5 克")
                == ["阿司匹林肠溶片", "二甲双胍"])
        #expect(VoiceProfileRules.medicationNames(from: "胰岛素注射液") == ["胰岛素注射液"])
        #expect(VoiceProfileRules.medicationNames(from: "维生素B12 片") == ["维生素B12 片"])
        #expect(VoiceProfileRules.medicationNames(from: "和胃整肠丸") == ["和胃整肠丸"])
        #expect(VoiceProfileRules.medicationNames(from: "每天口服阿司匹林") == ["阿司匹林"])
        #expect(VoiceProfileRules.medicationUnitKind(from: "阿司匹林肠溶片") == "tablet")
        #expect(VoiceProfileRules.medicationUnitKind(from: "奥美拉唑胶囊") == "capsule")
        #expect(VoiceProfileRules.medicationUnitKind(from: "芬太尼贴") == "patch")
        #expect(VoiceProfileRules.medicationUnitKind(from: "胰岛素注射液") == "vial")
        #expect(VoiceProfileRules.medicationNames(from: "没有").isEmpty)
        #expect(VoiceProfileRules.medicationNames(from: "没吃药").isEmpty)
        #expect(VoiceProfileRules.medicationNames(from: "我没有吃药").isEmpty)
        #expect(VoiceProfileRules.medicationNames(from: "左甲状腺素钠片 50微克") == ["左甲状腺素钠片"])
        #expect(VoiceProfileRules.medicationNames(from: "清热解毒口服液") == ["清热解毒口服液"])
    }

    @Test func relationMapsOnlyKnownWords() {
        #expect(VoiceProfileRules.relation(from: "我女儿") == .child)
        #expect(VoiceProfileRules.relation(from: "爱人") == .partner)
        #expect(VoiceProfileRules.relation(from: "母亲") == .parent)
        #expect(VoiceProfileRules.relation(from: "外婆") == .grandparent)
        #expect(VoiceProfileRules.relation(from: "闺女") == .child)
        #expect(VoiceProfileRules.relation(from: "老伴") == .partner)
        #expect(VoiceProfileRules.relation(from: "老爸") == .parent)
        #expect(VoiceProfileRules.relation(from: "朋友") == .other)
        #expect(VoiceProfileRules.relation(from: "嗯") == nil)
        #expect(VoiceProfileRules.relation(from: "  ") == nil)
    }

    @Test func memberDraftSplitsNameRelationAndBirthDate() {
        let full = VoiceProfileRules.memberDraft(from: "我女儿张敏，1990年5月3日出生")
        #expect(full.name == "张敏")
        #expect(full.relation == .child)
        #expect(full.birthDate == "1990-05-03")
        let colloquial = VoiceProfileRules.memberDraft(from: "我闺女张敏")
        #expect(colloquial.name == "张敏")
        #expect(colloquial.relation == .child)
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
