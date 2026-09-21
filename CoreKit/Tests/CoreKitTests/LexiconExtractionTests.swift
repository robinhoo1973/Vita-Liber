import Foundation
import Testing
@testable import Domain

/// 词表锚定抽取金样（2026-09-21，FR25.12⑬）。
/// 不变式：所有产出值恒为原文**精确子串**（grounding 可逐字定位，BR-002 保真）；
/// 全 D 级（BR-003）；近失配只产候选、绝不改值（FR25.1 补注）。
@Suite("SU-M15-LEX-E2E · 词表锚定字段建议（指标行/处方行/近失配）")
struct LexiconExtractionTests {

    private var lexicon: MedicalLexicon { LexiconScannerTests.seededLexicon() }

    @Test func metricRowAnchoredToRawLabelValueUnit() {
        let lines = ["血红蛋白 116 g/L"]
        let drafts = LexiconExtraction.propose(lines: lines, lexicon: lexicon, existing: [],
                                               documentTypeKey: "lab_report")
        let label = drafts.first { $0.key == "raw_label" }
        #expect(label?.value == "血红蛋白")
        #expect(label?.sourceLineIndex == 0)
        #expect(drafts.contains { $0.key == "value" && $0.value == "116" })
        #expect(drafts.contains { $0.key == "unit" && $0.value == "g/L" })
        for draft in drafts {
            #expect(lines[0].contains(draft.value), "保真：建议值恒为原文子串")
            #expect(draft.grade == .ocrUnconfirmed, "词表产出恒 D 级（BR-003）")
        }
    }

    @Test func existingDraftSuppressesDuplicateProposal() {
        let line = "血红蛋白 116 g/L"
        let existing = [FieldDraft(key: "raw_label", value: "血红蛋白", confidence: 0.9, sourceLineIndex: 0)]
        let drafts = LexiconExtraction.propose(lines: [line], lexicon: lexicon, existing: existing,
                                               documentTypeKey: "lab_report")
        #expect(!drafts.contains { $0.key == "raw_label" }, "既有标签已占位，不重复建议")
    }

    @Test func prescriptionLineAnchorsDrugNameWithCompanions() {
        let line = "阿司匹林 100mg 口服 每日一次"
        let drafts = LexiconExtraction.propose(lines: [line], lexicon: lexicon, existing: [],
                                               documentTypeKey: "prescription")
        #expect(drafts.contains { $0.key == "drug_name" && $0.value == "阿司匹林" })
        #expect(drafts.contains { $0.key == "spec" })
        #expect(drafts.contains { $0.key == "route" && $0.value == "口服" })
        #expect(drafts.contains { $0.key == "frequency" && $0.value == "每日一次" })
        for draft in drafts {
            #expect(line.contains(draft.value), "保真：建议值恒为原文子串")
        }
    }

    @Test func bareDrugNameNeedsPrescriptionContext() {
        let line = "阿司匹林"
        let lab = LexiconExtraction.propose(lines: [line], lexicon: lexicon, existing: [],
                                            documentTypeKey: "lab_report")
        #expect(lab.isEmpty, "非处方文档 + 无伴随键：不产出（防标题行误报）")
        let rx = LexiconExtraction.propose(lines: [line], lexicon: lexicon, existing: [],
                                           documentTypeKey: "prescription")
        #expect(rx.contains { $0.key == "drug_name" && $0.value == "阿司匹林" })
    }

    @Test func nearMissCreatesCandidateWithoutRewritingValue() {
        let line = "血红蛋自 116 g/L"
        let drafts = LexiconExtraction.propose(lines: [line], lexicon: lexicon, existing: [],
                                               documentTypeKey: "lab_report")
        guard let label = drafts.first(where: { $0.key == "raw_label" }) else {
            Issue.record("应产出近失配标签草稿")
            return
        }
        #expect(label.value == "血红蛋自", "保真：原文不改写")
        #expect(label.candidates.contains { $0.value == "血红蛋白" }, "候选供用户点选")
        #expect(label.grade == .ocrUnconfirmed, "近失配仍为 D 级（BR-003）")
    }

    @Test func choosingCandidateSwitchesValueAndCodeResolution() {
        let resolution = CodeResolution(conceptId: "c-hgb", canonicalCode: "718-7",
                                        codingSystem: .loinc,
                                        displayZhHans: "血红蛋白", displayEn: "Hemoglobin",
                                        kind: .metric, canonicalUnit: "g/dL",
                                        matchedVia: .curated, confidence: 0.95)
        var draft = FieldDraft(key: "raw_label", value: "血红蛋自", confidence: 0.5, sourceLineIndex: 0)
        draft.candidates = [.init(value: "血红蛋白", confidence: 0.5, sourceLineIndex: 0,
                                  source: .gazetteer, codeResolution: resolution)]
        draft.chooseCandidate(draft.candidates[0])
        #expect(draft.value == "血红蛋白")
        #expect(draft.codeResolution?.canonicalCode == "718-7", "选定候选即选定其术语，编码建议随切")
        #expect(draft.grade == .ocrUnconfirmed, "换值即退回未确认（BR-003）")
        #expect(draft.candidateChosen)
    }
}
