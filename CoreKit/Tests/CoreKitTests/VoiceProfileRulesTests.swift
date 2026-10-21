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

    @Test func identifierFieldsTrimOnly() {
        #expect(VoiceProfileRules.normalizedValue(key: "idNo", value: "  110101199001011234 ") == "110101199001011234")
        #expect(VoiceProfileRules.normalizedValue(key: "insuranceNo", value: "   ") == nil)
        #expect(VoiceProfileRules.normalizedValue(key: "note", value: "x") == nil)
    }
}
