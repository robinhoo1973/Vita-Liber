import Foundation
import Testing
@testable import Domain
import Infrastructure

// binds: SU-M15-ASRFUSION — 通用策略（空词表/自定义词表/归一化/源权重）+ 多源来源组契约 + 医疗预设注入
@Suite("SU-M15-ASRFUSION · 通用融合策略与多源契约（Domain 无医学词表）")
struct HypothesisFusionPolicyTests {
    typealias F = HypothesisFusionFixtures

    static func classes(_ text: String, policy: HypothesisFusionPolicy = .generic) -> [HypothesisFusionTokenClass] {
        HypothesisFusionTokenizer.tokenize(text, policy: policy).map(\.tokenClass)
    }

    static func keys(_ text: String, policy: HypothesisFusionPolicy = .generic) -> [String] {
        HypothesisFusionTokenizer.tokenize(text, policy: policy).map(\.key)
    }

    // MARK: 空词表策略 = 无领域假设

    @Test("空策略不含任何领域词表；只保留通用数字/单位符号保护")
    func genericPolicyContainsNoDomainVocabulary() {
        let policy = HypothesisFusionPolicy.generic
        #expect(policy.vocabulary.unitTerms.isEmpty)
        #expect(policy.vocabulary.negationTerms.isEmpty)
        #expect(policy.vocabulary.polarityTerms.isEmpty)
        #expect(policy.vocabulary.negationContractionSuffixes.isEmpty)
        #expect(policy.protectedTerms.isEmpty)
        #expect(policy.sourceWeights.isEmpty)
        #expect(policy.protectedTokenClasses == [.number, .unit, .negation, .polarity])
        #expect(!policy.protectedTokenClasses.contains(.word))
        #expect(policy.clauseFreezingTokenClasses == [.negation])
    }

    @Test("空策略下医学词只作普通词：左/不/毫克 不分类保护，数字仍是数字")
    func genericPolicyLeavesWordsUnclassified() {
        #expect(Self.classes("左 不 毫克 500") == [.word, .word, .word, .word, .number])
        #expect(Self.keys("五百") == ["#500"])
        #expect(Self.classes("I don't cough") == [.word, .word, .word])
    }

    @Test("自定义词表驱动分词：单位/否定/极性均来自调用方")
    func customVocabularyDrivesTokenClasses() {
        let policy = HypothesisFusionPolicy(vocabulary: .init(
            unitTerms: ["块"], negationTerms: ["not"], polarityTerms: ["up"],
            negationContractionSuffixes: ["n't"]))
        #expect(Self.classes("三块 not up", policy: policy) == [.number, .unit, .negation, .polarity])
        #expect(Self.classes("I can't go", policy: policy) == [.word, .negation, .word])
    }

    @Test("策略内受保护词条按同一分词匹配（大小写不敏感）")
    func policyProtectedTermsMatchKeySequences() {
        let policy = HypothesisFusionPolicy(protectedTerms: ["FooBar"])
        let flags = HypothesisFusionTokenizer.tokenize("keep foobar here", policy: policy).map(\.isProtectedTerm)
        #expect(flags == [false, true, false])
    }

    // MARK: 通用内核 + 非医学文本

    @Test("空策略可独立完成非医学文本融合（只选不生成、确定性）")
    func genericPolicyFusesNonMedicalText() {
        let primary = F.hypothesis(F.primaryID, "helo world")
        let secondaries = [F.hypothesis(F.appleZh, "hello world"), F.hypothesis(F.sense, "hello world")]
        let options = HypothesisFusionOptions(mode: .gatedRewrite, policy: .generic)
        let first = HypothesisFusion.fuse(primary: primary, secondaries: secondaries, calibration: F.standard,
                                          options: options)
        let second = HypothesisFusion.fuse(primary: primary, secondaries: secondaries.reversed(),
                                           calibration: F.standard, options: options)
        #expect(first.text == "hello world")
        #expect(first.edits.count == 1)
        #expect(first.edits.first?.original == "helo")
        #expect(first.edits.first?.replacement == "hello")
        #expect(first == second)
    }

    // MARK: 归一化选项

    @Test("归一化开关逐项生效：大小写/弯撇号/中文数字/拼音")
    func normalizationOptionsAreHonored() {
        let caseSensitive = HypothesisFusionPolicy(
            normalization: .init(foldsLatinCase: false))
        #expect(Self.keys("OK ok", policy: caseSensitive) == ["OK", "ok"])
        #expect(Self.keys("OK ok") == ["ok", "ok"])

        let rawApostrophe = HypothesisFusionPolicy(
            normalization: .init(foldsApostrophes: false))
        #expect(Self.keys("don’t", policy: rawApostrophe) != Self.keys("don't", policy: rawApostrophe))
        #expect(Self.keys("don’t") == Self.keys("don't"))

        let rawNumerals = HypothesisFusionPolicy(
            normalization: .init(evaluatesChineseNumerals: false))
        #expect(Self.keys("五百", policy: rawNumerals) == ["五", "百"])
        #expect(Self.keys("五百") == ["#500"])

        let noPhonetics = HypothesisFusionPolicy(
            normalization: .init(usesPhoneticAlignment: false))
        let token = HypothesisFusionTokenizer.tokenize("是", policy: noPhonetics)[0]
        #expect(token.phonetic == token.key)
    }

    // MARK: 源权重

    @Test("源权重缩放校准得分；缺省/非法值按 1（不改变默认行为）")
    func sourceWeightsScaleCalibrationScores() {
        let policy = HypothesisFusionPolicy.generic
        #expect(policy.effectiveSourceWeight(for: "absent") == 1)
        #expect(HypothesisFusionPolicy(sourceWeights: ["e": .nan]).effectiveSourceWeight(for: "e") == 1)
        #expect(HypothesisFusionPolicy(sourceWeights: ["e": -1]).effectiveSourceWeight(for: "e") == 1)
        #expect(HypothesisFusionPolicy(sourceWeights: ["e": 0.5]).effectiveSourceWeight(for: "e") == 0.5)

        let primary = F.hypothesis(F.primaryID, "今天头疼得历害")
        let secondaries = [F.hypothesis(F.appleZh, "今天头疼得厉害"),
                           F.hypothesis(F.sense, "今天头疼得厉害")]
        let unweighted = HypothesisFusion.fuse(
            primary: primary, secondaries: secondaries, calibration: F.standard,
            options: HypothesisFusionOptions(mode: .gatedRewrite, tau: 2.0))
        // 主轨 log(47)≈3.85；两副轨各 log(34.5)≈3.54，合计 7.08，边际≈3.23 > τ=2 → 可改写。
        #expect(unweighted.text == "今天头疼得厉害")
        let weighted = HypothesisFusion.fuse(
            primary: primary, secondaries: secondaries, calibration: F.standard,
            options: HypothesisFusionOptions(
                mode: .gatedRewrite, tau: 2.0,
                policy: HypothesisFusionPolicy(sourceWeights: [F.appleZh: 0.5, F.sense: 0.5])))
        // 副轨得分减半（合计≈3.54 < 主轨≈3.85）→ 保留主轨并记 belowGate。
        #expect(weighted.text == "今天头疼得历害")
        #expect(weighted.disputes.map(\.reason) == [.belowGate])
    }

    // MARK: 多源入口与来源组

    static func sources(primary: String, secondaries: [(String, String, String)]) -> [HypothesisFusionSource] {
        [HypothesisFusionSource(hypothesis: F.hypothesis(F.primaryID, primary), sourceGroup: "sherpa",
                                role: .primary)]
            + secondaries.map {
                HypothesisFusionSource(hypothesis: F.hypothesis($0.0, $0.1), sourceGroup: $0.2,
                                       role: .secondary)
            }
    }

    @Test("多源入口与旧入口结果一致，并输出来源组（ASR 主轨 + Apple 中/英）")
    func multiSourceMatchesLegacyAndReportsGroups() {
        let primary = F.hypothesis(F.primaryID, "今天头疼得历害")
        let secondaries = [F.hypothesis(F.appleZh, "今天头疼得厉害"),
                           F.hypothesis(F.appleEn, "today head pain")]
        let legacy = HypothesisFusion.fuse(primary: primary, secondaries: secondaries,
                                           calibration: F.standard, options: F.scriptOptions)
        let sources = [
            HypothesisFusionSource(hypothesis: primary, sourceGroup: "sherpa", role: .primary),
            HypothesisFusionSource(hypothesis: secondaries[0], sourceGroup: "apple-speech", role: .secondary),
            HypothesisFusionSource(hypothesis: secondaries[1], sourceGroup: "apple-speech", role: .secondary),
        ]
        let multi = HypothesisFusion.fuse(sources: sources, calibration: F.standard,
                                          options: F.scriptOptions)
        #expect(multi.text == legacy.text)
        #expect(multi.edits == legacy.edits)
        #expect(multi.disputes == legacy.disputes)
        #expect(multi.sources == legacy.sources)
        #expect(multi.pairObservations == legacy.pairObservations)
        #expect(multi.sourceGroups.count == multi.sources.count)
        #expect(multi.sourceGroups == ["sherpa", "apple-speech", "apple-speech"])
    }

    @Test("多源输入顺序置换不改变结果")
    func multiSourceIsPermutationInvariant() {
        let sources = Self.sources(primary: "今天头疼得历害",
                                   secondaries: [("apple-zh", "今天头疼得厉害", "apple-speech"),
                                                 ("apple-en", "today head pain", "apple-speech"),
                                                 ("sense-voice", "今天头疼得厉害", "sherpa")])
        let baseline = HypothesisFusion.fuse(sources: sources, calibration: F.standard,
                                             options: F.scriptOptions)
        for order in [[0, 2, 3, 1], [3, 1, 0, 2], [2, 3, 1, 0]] {
            let permuted = order.map { sources[$0] }
            #expect(HypothesisFusion.fuse(sources: permuted, calibration: F.standard,
                                          options: F.scriptOptions) == baseline)
        }
    }

    @Test("OCR 契约：Paddle 主轨 + Apple Vision 副轨共用同一入口")
    func ocrSourcesShareTheSameEntryPoint() {
        let sources = [
            HypothesisFusionSource(hypothesis: F.hypothesis("paddle-ppocrv6-rec", "血红蛋自"),
                                   sourceGroup: "paddle", role: .primary),
            HypothesisFusionSource(hypothesis: F.hypothesis("apple-vision", "血红蛋白"),
                                   sourceGroup: "apple-vision", role: .secondary),
        ]
        let calibration = F.calibration([("paddle-ppocrv6-rec", 0.90), ("apple-vision", 0.92)])
        let result = HypothesisFusion.fuse(sources: sources, calibration: calibration,
                                           options: HypothesisFusionOptions(mode: .gatedRewrite, tau: 0))
        #expect(result.text == "血红蛋白")
        #expect(result.sourceGroups == ["paddle", "apple-vision"])
    }

    @Test("无主轨 / 多主轨 fail-closed：不挑主轨、不改写")
    func multiSourceRequiresExactlyOnePrimary() {
        let onlySecondary = HypothesisFusionSource(hypothesis: F.hypothesis(F.appleZh, "今天头疼得厉害"),
                                                   sourceGroup: "apple-speech", role: .secondary)
        let noPrimary = HypothesisFusion.fuse(sources: [onlySecondary], calibration: F.standard)
        #expect(noPrimary.fallback == .noPrimarySource)
        #expect(noPrimary.text.isEmpty)
        #expect(noPrimary.edits.isEmpty)
        let twoPrimaries = HypothesisFusion.fuse(sources: [
            HypothesisFusionSource(hypothesis: F.hypothesis(F.primaryID, "今天头疼得历害"),
                                   sourceGroup: "sherpa", role: .primary),
            HypothesisFusionSource(hypothesis: F.hypothesis(F.appleZh, "今天头疼得厉害"),
                                   sourceGroup: "apple-speech", role: .primary),
        ], calibration: F.standard)
        #expect(twoPrimaries.fallback == .ambiguousPrimary)
        #expect(twoPrimaries.text.isEmpty)
    }

    @Test("源级可产出脚本覆盖 options 声明（英文实例不在汉字列投票）")
    func sourceLevelScriptsOverrideOptions() {
        let sources = [
            HypothesisFusionSource(hypothesis: F.hypothesis(F.primaryID, "你说的很对"),
                                   sourceGroup: "sherpa", role: .primary),
            HypothesisFusionSource(hypothesis: F.hypothesis(F.appleEn, "near show the hen dui"),
                                   sourceGroup: "apple-speech", role: .secondary,
                                   producibleScripts: [.latin, .digit, .other]),
        ]
        let result = HypothesisFusion.fuse(sources: sources, calibration: F.standard,
                                           options: HypothesisFusionOptions(producibleScripts: [:]))
        #expect(result.text == "你说的很对")
        #expect(result.edits.isEmpty)
        #expect(result.disputes.isEmpty)
    }

    // MARK: 医疗预设注入 = 既有行为

    @Test("医疗预设把原 Domain 词表作为调用方策略注入")
    func medicalPresetInjectsVocabulary() {
        let policy = HypothesisFusionMedicalPolicy.standard
        #expect(Self.classes("五百毫克不发热", policy: policy)
                == [.number, .unit, .unit, .negation, .word, .word])
        #expect(Self.classes("左侧阳性", policy: policy) == [.polarity, .word, .polarity, .polarity])
        let required = ["阴性", "阳性", "左", "右", "饭前", "饭后", "increase", "decrease", "stop"]
        #expect(Set(policy.vocabulary.polarityTerms).isSuperset(of: required))
        #expect(!policy.vocabulary.polarityTerms.contains("上"))
        #expect(!policy.vocabulary.polarityTerms.contains("下"))
    }

    @Test("采集层策略注入：医疗预设保护否定，空策略下 what-if 可改写")
    func recognitionDebugCaptureUsesInjectedPolicy() {
        let input = RecognitionDebugCapture.Input(
            captureID: "policy", modality: .asr, createdAt: "t", deliveredText: "我不发热",
            segments: [RecognitionDebugCapture.Segment(index: 0, hypotheses: [
                RecognitionDebugCapture.Hypothesis(engineID: "qwen3", sourceGroup: "sherpa", role: .primary,
                                                   text: "我不发热"),
                RecognitionDebugCapture.Hypothesis(engineID: "apple-zh-CN", sourceGroup: "apple-speech",
                                                   role: .secondary, locale: "zh-CN", text: "我没发热"),
                RecognitionDebugCapture.Hypothesis(engineID: "apple-en-US", sourceGroup: "apple-speech",
                                                   role: .secondary, locale: "en-US", text: ""),
                RecognitionDebugCapture.Hypothesis(engineID: "sense-voice", sourceGroup: "sherpa",
                                                   role: .secondary, text: "我没发热"),
            ])])
        let medical = RecognitionDebugCapture.fuse(input, policy: HypothesisFusionMedicalPolicy.standard)
        #expect(medical.reviewOnlyText == "我不发热")
        #expect(medical.whatIfText == "我不发热")
        #expect(medical.editCount == 0)
        #expect(medical.disputedSegmentCount == 1)
        let generic = RecognitionDebugCapture.fuse(input)
        #expect(generic.reviewOnlyText == "我不发热")
        #expect(generic.whatIfText == "我没发热")
        #expect(generic.editCount == 1)
    }
}
