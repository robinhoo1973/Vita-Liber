import Foundation
import Testing
@testable import Domain

/// 语音侧词表锚定金样（2026-09-21，FR25.12⑪ 词表锚定轮）。
/// 绑定：`// binds: SU-M15-LEX-VOICE`（语音锚定 + 意图整合统一口）。
/// 纪律与 OCR 侧同族：值恒为原文子串；近失配仅候选；原文草稿恒首位。
@Suite("SU-M15-LEX-VOICE · 语音词表锚定与意图整合")
struct VoiceLexiconAnchoringTests {

    private var lexicon: MedicalLexicon { LexiconScannerTests.seededLexicon() }

    @Test func exactDrugHitAnchorsNameAndCompanions() {
        let text = "阿司匹林 胶囊 口服 每日一次"
        let anchor = VoiceLexiconAnchoring.anchor(text, lexicon: lexicon)
        #expect(anchor.hasMedicationEvidence)
        let keys = Set(anchor.drafts.map(\.key))
        #expect(keys == ["drug_name", "drug_form", "route", "frequency"])
        guard let name = anchor.drafts.first(where: { $0.key == "drug_name" }) else {
            Issue.record("药名草稿应在列")
            return
        }
        #expect(name.value == "阿司匹林", "值恒为转写原文子串")
        #expect(name.rawText == text)
        #expect(name.source == .gazetteer)
        // 伴随槽位值同为原文子串
        for draft in anchor.drafts {
            #expect(text.contains(draft.value), "槽位值必须可在转写中原样定位")
        }
    }

    @Test func companionOnlyEvidenceStillCountsWhenTwoOrMore() {
        let anchor = VoiceLexiconAnchoring.anchor("胶囊 口服", lexicon: lexicon)
        #expect(anchor.hasMedicationEvidence, "≥2 伴随槽位构成药草稿证据")
        #expect(anchor.drafts.map(\.key) == ["drug_form", "route"])
    }

    @Test func secondDrugBecomesCandidateNotSecondRow() {
        let text = "阿司匹林和氯吡格雷"
        let anchor = VoiceLexiconAnchoring.anchor(text, lexicon: lexicon)
        guard let name = anchor.drafts.first(where: { $0.key == "drug_name" }) else {
            Issue.record("药名草稿应在列")
            return
        }
        #expect(name.value == "阿司匹林", "首个命中为值")
        #expect(name.candidates.contains { $0.value == "氯吡格雷" }, "次个药名作候选供点选")
    }

    @Test func nearMissYieldsCandidateOnlyAndKeepsOriginalValue() {
        // 「阿司匹灵」= 同音字误识（灵/林）——距离 1 应出候选，但值恒为原文。
        let text = "我吃的是阿司匹灵"
        let anchor = VoiceLexiconAnchoring.anchor(text, lexicon: lexicon)
        guard let name = anchor.drafts.first(where: { $0.key == "drug_name" }) else {
            Issue.record("近失配应产出候选草稿")
            return
        }
        #expect(name.value == "阿司匹灵", "绝不自动改写转写（FR25.1）")
        #expect(name.candidates.contains { $0.value == "阿司匹林" })
        #expect(!anchor.hasMedicationEvidence, "近失配是提问不是断言——不计入意图证据")
    }

    @Test func integratePromotesUnknownAndKeepsTranscriptFirst() {
        let text = "阿司匹林 每日一次"
        let note = VoiceInputTemplate.fallbackDraft(value: text, confidence: 0.9)
        let unknown = UnderstandingResult(suggestedTarget: VoiceIntentKey.unknown.rawValue,
                                          targetConfidence: 0.6, fields: [note])
        let merged = VoiceLexiconAnchoring.integrate(unknown, text: text, lexicon: lexicon)
        #expect(merged.suggestedTarget == VoiceIntentKey.appendMedDraft.rawValue)
        #expect(merged.fields.first?.value == text, "原文草稿保持首位（分发只取 first）")
        #expect(merged.fields.contains { $0.key == "drug_name" })
        #expect(merged.targetConfidence >= 0.7)
    }

    @Test func integrateLeavesJudgedIntentsIntact() {
        let text = "明天八点提醒我买阿司匹林"
        let reminder = UnderstandingResult(suggestedTarget: VoiceIntentKey.createReminder.rawValue,
                                           targetConfidence: 0.8,
                                           fields: [FieldDraft(key: "hour", value: "8", confidence: 0.8)])
        let merged = VoiceLexiconAnchoring.integrate(reminder, text: text, lexicon: lexicon)
        #expect(merged.suggestedTarget == VoiceIntentKey.createReminder.rawValue, "已判定的去向不因词表证据改变")
        #expect(merged.fields.count == 1, "结构化意图字段不并入词表草稿（稳定性优先）")
    }

    @Test func integrateWeakEvidenceMergesWithoutPromotion() {
        let text = "就写每日一次吧"
        let note = VoiceInputTemplate.fallbackDraft(value: text, confidence: 0.9)
        let unknown = UnderstandingResult(suggestedTarget: VoiceIntentKey.unknown.rawValue,
                                          targetConfidence: 0.6, fields: [note])
        let merged = VoiceLexiconAnchoring.integrate(unknown, text: text, lexicon: lexicon)
        #expect(merged.suggestedTarget == VoiceIntentKey.unknown.rawValue, "单伴随槽位不升格")
        #expect(merged.fields.count == 2, "弱证据仍并入供确认卡呈现")
        #expect(merged.fields.first?.value == text)
    }

    @Test func integratePromotesNilTargetWithEvidence() {
        let text = "氯吡格雷 口服"
        let draft = UnderstandingResult(suggestedTarget: nil, targetConfidence: 0,
                                        fields: [VoiceInputTemplate.fallbackDraft(value: text, confidence: 0.7)])
        let merged = VoiceLexiconAnchoring.integrate(draft, text: text, lexicon: lexicon)
        #expect(merged.suggestedTarget == VoiceIntentKey.appendMedDraft.rawValue)
    }

    @Test func extractMedDraftFillsSlotsWithLexicon() {
        let text = "阿司匹林 每日一次"
        let drafts = VoiceIntentCatalog.extract(for: .appendMedDraft, text: text,
                                                confidence: 0.9, lexicon: lexicon)
        #expect(drafts.first?.value == text, "原文草稿恒首位（期一用药草稿与速记同走速记分发）")
        #expect(drafts.contains { $0.key == "drug_name" && $0.value == "阿司匹林" })
        #expect(drafts.contains { $0.key == "frequency" })
    }

    @Test func extractMedDraftWithoutLexiconFallsBackToTranscriptOnly() {
        let text = "阿司匹林 每日一次"
        let drafts = VoiceIntentCatalog.extract(for: .appendMedDraft, text: text, confidence: 0.9)
        #expect(drafts.count == 1, "词表不可用时保持既有回落语义")
        #expect(drafts.first?.value == text)
    }

    @Test func emptyInputsYieldEmptyAnchor() {
        #expect(VoiceLexiconAnchoring.anchor("", lexicon: lexicon).drafts.isEmpty)
        #expect(VoiceLexiconAnchoring.anchor("阿司匹林", lexicon: MedicalLexicon(entries: [])).drafts.isEmpty)
    }
}
