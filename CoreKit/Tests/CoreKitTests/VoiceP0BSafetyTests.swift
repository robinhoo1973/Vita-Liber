import Foundation
import Testing
@testable import Domain

// binds: SU-M15-VOICE — P0-B 语音安全面
/// round3 P0-B（2026-11-03 多假设融合第三轮 §8）：融合与否都要先做的三件安全前置——
/// ① BR-012 急救扫描覆盖交付文本与各引擎原生 1-best（不含低位 n-best）；
/// ② 药名热词与混说开关解绑（混说关 = 只注入已确认药名，混说开 = 词表不变）；
/// ③ FR17.4 B2 放行线追加混说真人配额（≥150）。
@Suite("SU-M15-VOICE · P0-B 语音安全面（急救全量扫描/药名热词解绑/混说配额）")
struct VoiceP0BSafetyTests {

    private func result(_ text: String, hypotheses: [TranscriptionHypothesis] = []) -> TranscriptionResult {
        TranscriptionResult(text: text, confidence: 0.9, resolvedLocale: "zh-Hans-CN", segmented: false,
                            segments: [text], engineID: "qwen3", hypotheses: hypotheses)
    }

    // MARK: - ① BR-012 急救全量扫描

    @Test func deliveredTextHitReturnsDeliveredTextFirst() {
        let hit = result("我胸痛得厉害", hypotheses: [
            TranscriptionHypothesis(engineID: "classic", text: "我胸闷"),
        ])
        #expect(TranscriptionSafety.emergencyText(in: hit) == "我胸痛得厉害",
                "交付文本命中时回传交付文本（与引入假设前一致）")
    }

    @Test func hypothesisOnlyHitReturnsFirstMatchingRawHypothesis() {
        let hit = result("我兄通得厉害", hypotheses: [
            TranscriptionHypothesis(engineID: "qwen3", text: "我兄通得厉害"),
            TranscriptionHypothesis(engineID: "classic", localeIdentifier: "zh-Hans-CN", text: "我胸痛得厉害"),
            TranscriptionHypothesis(engineID: "classic:en-US", localeIdentifier: "en-US", text: "chest pain"),
        ])
        #expect(TranscriptionSafety.emergencyText(in: hit) == "我胸痛得厉害",
                "交付文本被改写丢掉急救词时，任一原始 1-best 命中即急救，按假设顺序取第一段")
    }

    @Test func emptyDeliveredTextStillSurfacesRawHypothesisHit() {
        let hit = result("", hypotheses: [TranscriptionHypothesis(engineID: "sensevoice", text: "救命")])
        #expect(TranscriptionSafety.emergencyText(in: hit) == "救命", "主轨为空、副引擎听到急救词也必须急救")
    }

    @Test func nBestOnlyHitDoesNotTriggerEmergency() {
        let token = TranscriptionToken(text: "兄通", confidence: 0.4, alternatives: ["胸痛"])
        let quiet = result("我兄通得厉害", hypotheses: [
            TranscriptionHypothesis(engineID: "classic", text: "我兄通得厉害", tokens: [token],
                                    confidenceKind: .engineNative,
                                    alternativeTexts: ["我胸痛得厉害", "chest pain"]),
        ])
        #expect(TranscriptionSafety.emergencyText(in: quiet) == nil,
                "同一引擎的低位 n-best / 逐词替代写法不参与急救判定（防误触发）")
    }

    @Test func emptyHypothesesBehaveExactlyLikeLegacyDeliveredTextScan() {
        let texts = ["我胸闷", "我呼吸困難", "Call 911 now", "血糖6.2", "", "   ", "今天头有点晕"]
        for text in texts {
            let legacy = EmergencyKeywordRules.match(text)
            let scanned = TranscriptionSafety.emergencyText(in: result(text))
            #expect((scanned != nil) == legacy, "\(text)")
            if legacy {
                #expect(scanned == text, "\(text)")
            }
        }
    }

    // MARK: - ② 药名热词与混说开关解绑

    /// 解绑前 `MixedSpeechVocabulary.terms` 的逐行副本，作为「混说开词表不变」的基准实现。
    private func legacyTerms(primaryLocale: String, otherLocales: [String],
                             recentDrugNames: [String], limit: Int = MixedSpeechVocabulary.limit) -> [String] {
        let limit = min(MixedSpeechVocabulary.limit, max(0, limit))
        var seen = Set<String>()
        var out: [String] = []
        func add(_ term: String) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, out.count < limit, seen.insert(trimmed).inserted else { return }
            out.append(trimmed)
        }
        recentDrugNames.forEach(add)
        MixedSpeechVocabulary.units.forEach(add)
        let locales = [primaryLocale] + otherLocales
        if locales.contains(where: { $0.hasPrefix("en") }) {
            MixedSpeechVocabulary.englishMedical.forEach(add)
        }
        return out
    }

    @Test func mixedOffInjectsConfirmedDrugNamesOnly() {
        let terms = MixedSpeechVocabulary.contextualStrings(
            mixedInput: false, primaryLocale: "zh-Hans-CN", otherLocales: ["en-US"],
            recentDrugNames: ["阿莫西林胶囊", " 二甲双胍 ", "阿莫西林胶囊", "", "Metformin"])
        #expect(terms == ["阿莫西林胶囊", "二甲双胍", "Metformin"], "保序、去空白、去重")
        #expect(!terms.contains("mmHg"), "医疗单位只属于混说词表")
        #expect(!terms.contains("CT"), "英文医学词只属于混说词表")
    }

    @Test func drugNameTermsRespectSDKLimit() {
        let drugs = (0..<150).map { "药名\($0)" }
        let assembled = MixedSpeechVocabulary.contextualStrings(
            mixedInput: false, primaryLocale: "zh-Hans-CN", otherLocales: [], recentDrugNames: drugs)
        #expect(assembled == Array(drugs.prefix(MixedSpeechVocabulary.limit)))
        let oversized = MixedSpeechVocabulary.drugNameTerms(recentDrugNames: drugs, limit: 200)
        #expect(oversized.count == MixedSpeechVocabulary.limit, "调用方上限不得突破 SDK 上限")
        #expect(MixedSpeechVocabulary.drugNameTerms(recentDrugNames: drugs, limit: 3) == ["药名0", "药名1", "药名2"])
        #expect(MixedSpeechVocabulary.drugNameTerms(recentDrugNames: drugs, limit: -1).isEmpty)
    }

    @Test func mixedOffWithoutConfirmedDrugNamesInjectsNothing() {
        let none = MixedSpeechVocabulary.contextualStrings(
            mixedInput: false, primaryLocale: "en-US", otherLocales: ["zh-Hans-CN"], recentDrugNames: [])
        #expect(none.isEmpty)
        let blank = MixedSpeechVocabulary.contextualStrings(
            mixedInput: false, primaryLocale: "zh-Hans-CN", otherLocales: [], recentDrugNames: ["", "  \n"])
        #expect(blank.isEmpty)
    }

    @Test func mixedOnVocabularyIsUnchangedFromLegacyTerms() {
        let drugLists: [[String]] = [
            [],
            ["阿莫西林胶囊", " 二甲双胍 ", "阿莫西林胶囊", ""],
            (0..<150).map { "药名\($0)" },
            ["mmHg", "CT", "布洛芬"],
        ]
        let localeSets: [(primary: String, others: [String])] = [
            ("zh-Hans-CN", []), ("zh-Hans-CN", ["en-US"]), ("en-US", []), ("en-US", ["zh-Hans-CN"]),
        ]
        let limits = [MixedSpeechVocabulary.limit, 5, 0, 200, -1]
        for drugs in drugLists {
            for locales in localeSets {
                for limit in limits {
                    let legacy = legacyTerms(primaryLocale: locales.primary, otherLocales: locales.others,
                                             recentDrugNames: drugs, limit: limit)
                    let terms = MixedSpeechVocabulary.terms(primaryLocale: locales.primary,
                                                            otherLocales: locales.others,
                                                            recentDrugNames: drugs, limit: limit)
                    let assembled = MixedSpeechVocabulary.contextualStrings(
                        mixedInput: true, primaryLocale: locales.primary, otherLocales: locales.others,
                        recentDrugNames: drugs, limit: limit)
                    #expect(terms == legacy)
                    #expect(assembled == legacy)
                }
            }
        }
    }

    // MARK: - ③ FR17.4 混说真人配额

    private func report(mixed: Int?) -> VoiceCalibration.Report {
        var quota = ["zh-Hans-CN": 300, "en-US": 50]
        if let mixed { quota[VoiceCalibration.mixedQuotaKey] = mixed }
        return VoiceCalibration.Report(humanSampleCount: 500, numericAccuracy: 0.95,
                                       structureRate: 0.9, localeQuota: quota)
    }

    @Test func mixedQuotaThresholdLockedToOwnerDefault() {
        #expect(VoiceCalibration.requiredMixedSamples == 150)
        #expect(VoiceCalibration.mixedQuotaKey == "mixed")
    }

    @Test func mixedQuotaBoundaryGatesReleaseLine() {
        let short = report(mixed: 149)
        #expect(!short.passesReleaseLine, "其余达标但混说 149 条不得放行")
        #expect(short.blockingReasons == ["混说真人语料 149/150 条"])
        let enough = report(mixed: 150)
        #expect(enough.passesReleaseLine)
        #expect(enough.blockingReasons.isEmpty)
        let missing = report(mixed: nil)
        #expect(!missing.passesReleaseLine, "缺混说键按 0 计——缺语料一律不过")
        #expect(missing.blockingReasons == ["混说真人语料 0/150 条"])
    }

    @Test func mixedQuotaCountsHumanRecordedSamplesOnly() {
        func sample(_ index: Int, locale: String, human: Bool) -> VoiceCalibration.Sample {
            VoiceCalibration.Sample(id: "q-\(index)", transcript: "血糖6.2", kind: "metric", locale: locale,
                                    isHumanRecorded: human, expected: ["glucose": "6.2"])
        }
        let mandarin = (0..<351).map { sample($0, locale: "zh-Hans-CN", human: true) }
        let mixedHuman = (351..<500).map { sample($0, locale: VoiceCalibration.mixedQuotaKey, human: true) }
        let mixedScripted = (500..<540).map { sample($0, locale: VoiceCalibration.mixedQuotaKey, human: false) }
        let corpus = VoiceCalibration.Corpus(version: "p0b", samples: mandarin + mixedHuman + mixedScripted)
        let report = VoiceCalibration.evaluate(corpus: corpus) { _ in ["glucose": "6.2"] }
        #expect(report.humanSampleCount == 500)
        #expect(report.localeQuota[VoiceCalibration.mixedQuotaKey] == 149, "手写/合成混说样本不计入配额")
        #expect(!report.passesReleaseLine)
        #expect(report.blockingReasons == ["混说真人语料 149/150 条"])
    }

    // MARK: - 共享契约：TranscriptionResult.hypotheses

    @Test func transcriptionResultDefaultsToNoHypothesesAndEquatableSeesThem() {
        let plain = TranscriptionResult(text: "血糖6.2", confidence: 0.9, resolvedLocale: "zh-Hans-CN", segmented: false)
        #expect(plain.hypotheses.isEmpty, "旧调用方不传证据 = 空，行为不变")
        let qwen = TranscriptionHypothesis(engineID: "qwen3", text: "血糖6.2")
        var withEvidence = plain
        withEvidence.hypotheses = [qwen]
        #expect(withEvidence != plain)
        var otherEngine = plain
        otherEngine.hypotheses = [TranscriptionHypothesis(engineID: "classic", text: "血糖6.2")]
        #expect(otherEngine != withEvidence)
        var nBest = withEvidence
        nBest.hypotheses[0].alternativeTexts = ["雪糖6.2"]
        #expect(nBest != withEvidence)
        let rebuilt = TranscriptionResult(text: "血糖6.2", confidence: 0.9, resolvedLocale: "zh-Hans-CN",
                                          segmented: false, hypotheses: [qwen])
        #expect(rebuilt == withEvidence)
    }
}
