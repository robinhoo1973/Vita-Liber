import Foundation
import Testing
@testable import Domain

/// 词表扫描器金样（2026-09-21，FR25.12⑬ 词表锚定轮）。
/// 绑定：`// binds: SU-M15-LEX`（词表锚定扫描统一口）。
@Suite("SU-M15-LEX · 词表锚定扫描与近失配候选")
struct LexiconScannerTests {

    /// 生产同源词表：直接消费 `CodeSetSeeds`（与生产码表装载同一份种子）。
    static func seededLexicon() -> MedicalLexicon {
        var entries: [LexiconEntry] = []
        for seed in CodeSetSeeds.aliases {
            entries.append(LexiconEntry(term: seed.aliasText, locale: seed.locale,
                                        category: .metric, conceptId: seed.conceptId,
                                        priority: seed.priority))
        }
        for seed in CodeSetSeeds.lexiconTerms {
            guard let category = LexiconCategory(rawValue: seed.category) else { continue }
            entries.append(LexiconEntry(term: seed.term, locale: seed.locale,
                                        category: category, conceptId: nil,
                                        priority: seed.priority))
        }
        return MedicalLexicon(entries: entries)
    }

    @Test func exactHitReturnsOriginalSubstringAndRange() {
        let lexicon = Self.seededLexicon()
        let line = "血红蛋白 116 g/L"
        let hits = lexicon.hits(in: line)
        guard let hit = hits.first(where: { $0.entry.category == .metric }) else {
            Issue.record("「血红蛋白」应命中指标词表")
            return
        }
        #expect(hit.value == "血红蛋白")
        #expect(line[hit.range] == hit.value, "命中区间回映射原文")
        #expect(hit.match == .exact)
        #expect(hit.entry.conceptId == "c-hgb")
    }

    @Test func longestMatchWinsForOverlappingTerms() {
        let lexicon = Self.seededLexicon()
        let hits = lexicon.hits(in: "总胆固醇 5.2 mmol/L")
        #expect(hits.first?.value == "总胆固醇", "最长匹配：不得截成「胆固醇」")
        #expect(hits.first?.entry.conceptId == "c-chol-mass")
    }

    @Test func caseFoldHitsEnglishAlias() {
        let lexicon = Self.seededLexicon()
        let hits = lexicon.hits(in: "hb 120 g/L")
        let hit = hits.first { $0.entry.conceptId == "c-hgb" && $0.entry.category == .metric }
        #expect(hit != nil, "大小写折叠应命中 Hb")
        #expect(hit?.match == .folded, "原文形态与词条不同 → folded")
    }

    @Test func traditionalAliasRowsHitWithoutFoldTable() {
        // 有界折叠表不含「紅」——台湾/香港用词靠显式 zh-Hant 行命中（设计如此）
        let lexicon = Self.seededLexicon()
        let hits = lexicon.hits(in: "血紅素 14.2 g/dL")
        #expect(hits.contains { $0.entry.conceptId == "c-hgb" })
    }

    @Test func nearMissFindsCorrectionCandidate() {
        let lexicon = Self.seededLexicon()
        let candidates = lexicon.nearMisses(for: "血红蛋自", category: .metric)
        #expect(candidates.contains { $0.term == "血红蛋白" }, "OCR 错字（自/白）应产近失配候选")
    }

    @Test func nearMissWorksForMedicationCategory() {
        let lexicon = Self.seededLexicon()
        let candidates = lexicon.nearMisses(for: "阿莫西材", category: .medication)
        #expect(candidates.contains { $0.term == "阿莫西林" })
    }

    @Test func nearMissRequiresSameFirstCharacterAndLengthFloor() {
        let lexicon = Self.seededLexicon()
        #expect(lexicon.nearMisses(for: "糖血病", category: .metric).isEmpty)
        #expect(lexicon.nearMisses(for: "血蛋", category: .metric).isEmpty, "低于长度门槛不产候选")
    }

    @Test func editDistanceBoundedBehavior() {
        #expect(MedicalLexicon.editDistance("abcd", "abcd", cap: 2) == 0)
        #expect(MedicalLexicon.editDistance("abcd", "abce", cap: 2) == 1)
        #expect(MedicalLexicon.editDistance("abcd", "axyd", cap: 2) == 2)
        #expect(MedicalLexicon.editDistance("", "ab", cap: 2) == 2)
    }
}
