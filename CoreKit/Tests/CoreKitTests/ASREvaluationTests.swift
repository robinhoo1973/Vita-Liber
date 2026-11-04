import Foundation
import Testing
@testable import Domain

// binds: SU-M15-ASREVAL — 杀手实验工具链：清单校验 / 逐句 oracle 与增益 / 保护类伤害 / 急救召回与误报 / 延迟 / 配对 bootstrap / 置信度 AUROC / harm-fix / 止损判定 / 渲染
@Suite("SU-M15-ASREVAL · 混说识别评测工具链（MER/oracle/保护类/急救/止损判定）")
struct ASREvaluationTests {

    // MARK: - 合成场景（非真实录音/转写）：7 句、39 个参考 token

    static let manifest = ASREvaluation.Manifest(utterances: [
        .init(utteranceID: "u1", audioPath: "mixed/u1.wav", reference: "Yes，你说的很对", tags: [.mixed]),
        .init(utteranceID: "u2", audioPath: "numeric/u2.wav", reference: "阿莫西林每次500毫克",
              tags: [.numeric, .drug], protectedTerms: ["阿莫西林"]),
        .init(utteranceID: "u3", audioPath: "negation/u3.wav", reference: "我不发热", tags: [.negation]),
        .init(utteranceID: "u4", audioPath: "emergency/u4.wav", reference: "我胸痛得厉害", tags: [.emergencyPositive]),
        .init(utteranceID: "u5", audioPath: "emergency/u5.wav", reference: "今天天气很好", tags: [.emergencyNegative]),
        .init(utteranceID: "u6", audioPath: "emergency/u6.wav", reference: "我没有胸痛",
              tags: [.negation, .emergencyNegative]),
        .init(utteranceID: "u7", audioPath: "english/u7.wav", reference: "take one tablet"),
    ])

    /// 主轨：只错 u7 一个词（tablet → table）。
    static let primaryHypotheses = [
        "u1": "Yes，你说的很对", "u2": "阿莫西林每次500毫克", "u3": "我不发热", "u4": "我胸痛得厉害",
        "u5": "今天天气很好", "u6": "我没有胸痛", "u7": "take one table",
    ]
    /// Apple-zh 连续：音译英文、数字写成汉字、丢「不」。
    static let appleChineseHypotheses = [
        "u1": "耶斯你说的很对", "u2": "阿莫西林每次五百毫克", "u3": "我发热", "u4": "我胸痛得厉害",
        "u5": "今天天气很好", "u6": "我没有胸痛", "u7": "忒克万泰布莱特",
    ]
    /// Apple-en：中文全丢，只有英文句全对。
    static let appleEnglishHypotheses = [
        "u1": "Yes near show the hen dui", "u2": "", "u3": "", "u4": "", "u5": "", "u6": "", "u7": "take one tablet",
    ]
    /// Apple-zh 同段切段：每句都比连续多错一个 token。
    static let segmentedHypotheses = [
        "u1": "耶斯你说的很队", "u2": "阿莫西林每次五百毫可", "u3": "我发烧", "u4": "我胸痛得利害",
        "u5": "今天天气很号", "u6": "我没有胸通", "u7": "忒克万泰布莱特了",
    ]

    static func run(_ engineID: String, _ hypotheses: [String: String],
                    latencies: [String: Double] = [:]) -> ASREvaluation.SystemRun {
        let results = manifest.utterances.compactMap { utterance -> ASREvaluation.UtteranceResult? in
            guard let text = hypotheses[utterance.utteranceID] else { return nil }
            return .recognized(utterance.utteranceID, hypothesis: text,
                               latencyMilliseconds: latencies[utterance.utteranceID])
        }
        return ASREvaluation.SystemRun(engineID: engineID, results: results)
    }

    /// 主轨假设 + 逐词置信度：唯一错词「table」取 `wrongWordConfidence`，其余 0.95。
    static func confidentRun(_ engineID: String, wrongWordConfidence: Double) -> ASREvaluation.SystemRun {
        let results = manifest.utterances.compactMap { utterance -> ASREvaluation.UtteranceResult? in
            guard let text = primaryHypotheses[utterance.utteranceID] else { return nil }
            let tokens = MixedErrorRate.tokenize(text).map { token -> TranscriptionToken in
                let confidence: Double = token.text == "table" ? wrongWordConfidence : 0.95
                return TranscriptionToken(text: token.text, confidence: confidence)
            }
            return .recognized(utterance.utteranceID, hypothesis: text, tokens: tokens)
        }
        return ASREvaluation.SystemRun(engineID: engineID, results: results)
    }

    static func baseRuns(primaryLatencies: [String: Double] = [:]) -> [ASREvaluation.SystemRun] {
        [run("qwen3", primaryHypotheses, latencies: primaryLatencies),
         run("classic:zh-CN", appleChineseHypotheses),
         run("classic:en-US", appleEnglishHypotheses)]
    }

    static func baseReport() -> ASREvaluation.Report {
        ASREvaluation.evaluate(manifest: manifest, runs: baseRuns())
    }

    /// 20 句同一英文参考：供 token 级消融（含/不含 Apple-en 的两条融合输出）。
    static let englishManifest = ASREvaluation.Manifest(utterances: (0..<20).map { index -> ASREvaluation.Utterance in
        ASREvaluation.Utterance(utteranceID: "e\(index)", audioPath: "english/e\(index).wav",
                                reference: "take one tablet", tags: [.mixed])
    })

    static func englishRun(_ engineID: String, hypothesis: (Int) -> String) -> ASREvaluation.SystemRun {
        let results = englishManifest.utterances.enumerated().map { index, utterance -> ASREvaluation.UtteranceResult in
            ASREvaluation.UtteranceResult.recognized(utterance.utteranceID, hypothesis: hypothesis(index))
        }
        return ASREvaluation.SystemRun(engineID: engineID, results: results)
    }

    static func observation(_ errorsA: Int, _ errorsB: Int, length: Int) -> ASREvaluation.PairedObservation {
        let denominator = Double(length)
        return ASREvaluation.PairedObservation(errorsA: errorsA, errorsB: errorsB, referenceLength: length,
                                               rateA: Double(errorsA) / denominator,
                                               rateB: Double(errorsB) / denominator)
    }

    private func close(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-9
    }

    // MARK: - 清单

    @Test func manifestDecodesFromJSONWithOptionalFields() throws {
        let json = """
        {"schemaVersion": 1, "utterances": [
          {"utteranceID": "a1", "audioPath": "mixed/a1.wav", "reference": "Yes，你说的很对", "tags": ["mixed"]},
          {"utteranceID": "a2", "audioPath": "numeric/a2.m4a", "reference": "阿莫西林每次500毫克",
           "tags": ["numeric", "drug"], "protectedTerms": ["阿莫西林"]},
          {"utteranceID": "a3", "audioPath": "english/a3.wav", "reference": "take one tablet"}
        ]}
        """
        let manifest = try ASREvaluation.decodeManifest(from: Data(json.utf8))
        #expect(manifest.utterances.count == 3)
        #expect(manifest.utterances[1].tags == [.numeric, .drug])
        #expect(manifest.utterances[1].protectedTerms == ["阿莫西林"])
        #expect(manifest.utterances[0].protectedTerms == nil)
        #expect(manifest.utterances[2].tags.isEmpty)
    }

    @Test func manifestValidationListsEveryIssue() {
        let manifest = ASREvaluation.Manifest(schemaVersion: 2, utterances: [
            .init(utteranceID: "x1", audioPath: "/abs/x1.wav", reference: "我不发热",
                  tags: [.emergencyPositive, .emergencyNegative]),
            .init(utteranceID: "x1", audioPath: "../x2.wav", reference: "。！"),
            .init(utteranceID: " ", audioPath: "x3.wav", reference: "好", protectedTerms: ["阿莫西林"]),
        ])
        #expect(ASREvaluation.validate(manifest) == [
            .unsupportedSchemaVersion(2),
            .invalidAudioPath("x1"),
            .conflictingEmergencyTags("x1"),
            .duplicateUtteranceID("x1"),
            .emptyReference("x1"),
            .invalidAudioPath("x1"),
            .emptyUtteranceID(index: 2),
            .protectedTermNotInReference(utteranceID: " ", term: "阿莫西林"),
        ])
        #expect(ASREvaluation.validate(Self.manifest).isEmpty)
    }

    @Test func invalidManifestThrowsInsteadOfProducingAGreenReport() {
        let empty = Data(#"{"schemaVersion": 1, "utterances": []}"#.utf8)
        #expect(throws: ASREvaluation.ManifestValidationError(issues: [.noUtterances])) {
            try ASREvaluation.decodeManifest(from: empty)
        }
        let unknownTag = Data(#"""
        {"schemaVersion": 1, "utterances": [{"utteranceID": "a", "audioPath": "a.wav", "reference": "好", "tags": ["urgent"]}]}
        """#.utf8)
        #expect(throws: DecodingError.self) {
            try ASREvaluation.decodeManifest(from: unknownTag)
        }
    }

    @Test func manifestTemplateFixtureDecodesAndCoversEveryTag() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/asr-eval/manifest.template.json")
        let manifest = try ASREvaluation.decodeManifest(from: Data(contentsOf: url))
        let tags = Set(manifest.utterances.flatMap { $0.tags })
        #expect(tags == Set(ASREvaluation.Tag.allCases))
    }

    @Test func utteranceResultCarriesContractTokensThroughJSON() throws {
        let evidence = TranscriptionHypothesis(
            engineID: "classic:zh-CN", localeIdentifier: "zh-CN", text: "我不发热",
            tokens: [TranscriptionToken(text: "我", start: 0, duration: 0.2, confidence: 0.9, alternatives: ["哦"]),
                     TranscriptionToken(text: "不发热")],
            confidenceKind: .engineNative)
        let run = ASREvaluation.SystemRun(engineID: "classic:zh-CN", results: [
            .recognized("u3", evidence: evidence, latencyMilliseconds: 12),
        ])
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(ASREvaluation.SystemRun.self, from: data)
        #expect(decoded == run)
        #expect(decoded.results.first?.tokens?.first?.alternatives == ["哦"])
        let bare = ASREvaluation.UtteranceResult.recognized(
            "u3", evidence: TranscriptionHypothesis(engineID: "qwen3", text: "我不发热"))
        #expect(bare.tokens == nil)
    }

    // MARK: - MER 汇总

    @Test func perSystemMERMicroAndMacro() throws {
        let report = Self.baseReport()
        #expect(report.includedEngineIDs == ["classic:en-US", "classic:zh-CN", "qwen3"])
        let primary = try #require(report.system("qwen3"))
        #expect(primary.overall.referenceTokenCount == 39)
        #expect(primary.overall.errorCount == 1)
        #expect(close(primary.overall.micro, 1.0 / 39.0))
        #expect(close(primary.overall.macro, 1.0 / 21.0))
        let chinese = try #require(report.system("classic:zh-CN"))
        #expect(chinese.overall.substitutions == 5)
        #expect(chinese.overall.deletions == 1)
        #expect(chinese.overall.insertions == 6)
        #expect(close(chinese.overall.micro, 12.0 / 39.0))
        #expect(close(chinese.overall.macro, (2.0 / 6 + 2.0 / 9 + 1.0 / 4 + 7.0 / 3) / 7))
        let english = try #require(report.system("classic:en-US"))
        #expect(english.overall.substitutions == 5)
        #expect(english.overall.deletions == 30)
        #expect(english.overall.insertions == 0)
        #expect(close(english.overall.micro, 35.0 / 39.0))
    }

    @Test func failedScoresAsEmptyHypothesisAndSkippedIsExcluded() throws {
        let flaky = ASREvaluation.SystemRun(engineID: "flaky", results: [
            .failed("u1", reason: "超时", latencyMilliseconds: 9_000),
            .skipped("u2", reason: "音频文件缺失"),
            .recognized("u3", hypothesis: "我不发热", latencyMilliseconds: 50),
        ])
        let report = ASREvaluation.evaluate(manifest: Self.manifest, runs: [
            flaky, .skipped("classic:en-US", reason: "未授权"),
        ])
        let summary = try #require(report.system("flaky"))
        #expect(summary.recognizedCount == 1)
        #expect(summary.failedCount == 1)
        #expect(summary.skippedCount == 5)
        #expect(summary.overall.utteranceCount == 2)
        #expect(summary.overall.referenceTokenCount == 10)
        #expect(summary.overall.deletions == 6)
        #expect(close(summary.overall.micro, 0.6))
        #expect(close(summary.overall.macro, 0.5))
        #expect(summary.latency.sampleCount == 1)
        #expect(summary.latency.first == 50)
        let skippedSystem = try #require(report.system("classic:en-US"))
        #expect(skippedSystem.skipReason == "未授权")
        #expect(skippedSystem.skippedCount == 7)
        #expect(report.includedEngineIDs == ["flaky"])
        #expect(report.utterances[0].systems.map { $0.engineID } == ["flaky"])
        #expect(report.utterances[1].score(for: "flaky")?.reason == "音频文件缺失")
        #expect(report.utterances[3].score(for: "flaky")?.reason == "无结果")
    }

    @Test func stratifiedMERPerTag() throws {
        let report = Self.baseReport()
        #expect(report.tagCounts.map { $0.count } == [1, 1, 2, 1, 1, 2])
        let chinese = try #require(report.system("classic:zh-CN"))
        #expect(close(chinese.rate(for: .mixed).micro, 2.0 / 6.0))
        #expect(close(chinese.rate(for: .numeric).micro, 2.0 / 9.0))
        #expect(close(chinese.rate(for: .drug).micro, 2.0 / 9.0))
        let negation = chinese.rate(for: .negation)
        #expect(negation.utteranceCount == 2)
        #expect(close(negation.micro, 1.0 / 9.0))
        #expect(close(negation.macro, 0.125))
        #expect(chinese.rate(for: .emergencyPositive).micro == 0)
        #expect(chinese.rate(for: .emergencyNegative).utteranceCount == 2)
    }

    @Test func reportIsIndependentOfRunOrderAndWarnsOnDuplicates() {
        let forward = ASREvaluation.evaluate(manifest: Self.manifest, runs: Self.baseRuns())
        let reversed = ASREvaluation.evaluate(manifest: Self.manifest, runs: Self.baseRuns().reversed())
        #expect(forward == reversed)
        let duplicated = ASREvaluation.evaluate(manifest: Self.manifest,
                                                runs: Self.baseRuns() + [Self.run("qwen3", Self.appleChineseHypotheses)])
        #expect(duplicated.system("qwen3") == forward.system("qwen3"))
        #expect(duplicated.warnings == ["系统 qwen3 重复提交：只取首份结果"])
    }

    // MARK: - 逐句 oracle

    @Test func sentenceOracleTakesPerUtteranceMinimum() throws {
        let report = Self.baseReport()
        let oracle = try #require(report.oracle)
        #expect(oracle.engineIDs == ["classic:en-US", "classic:zh-CN", "qwen3"])
        #expect(oracle.rate.errorCount == 0)
        #expect(report.utterances[6].oracleEngineIDs == ["classic:en-US"])
        #expect(report.utterances[3].oracleEngineIDs == ["classic:zh-CN", "qwen3"])
        let withoutEnglish = report.oracleRate(pool: ["qwen3", "classic:zh-CN"])
        #expect(withoutEnglish.errorCount == 1)
        #expect(close(withoutEnglish.micro, 1.0 / 39.0))
    }

    @Test func oracleGainIsLeaveOneOutInPercentagePoints() throws {
        let report = Self.baseReport()
        let english = try #require(report.oracleGain(of: "classic:en-US"))
        #expect(english.withoutSystem.errorCount == 1)
        #expect(english.withSystem.errorCount == 0)
        #expect(close(english.microGainPercentagePoints, 100.0 / 39.0))
        #expect(close(english.macroGainPercentagePoints, 100.0 / 21.0))
        let chinese = try #require(report.oracleGain(of: "classic:zh-CN"))
        #expect(chinese.microGainPercentagePoints == 0)
        let primary = try #require(report.oracleGain(of: "qwen3"))
        #expect(close(primary.microGainPercentagePoints, 500.0 / 39.0))
        #expect(report.oracleGain(of: "qwen3", pool: ["qwen3"]) == nil)
    }

    // MARK: - 保护类

    @Test func protectedClassHarmIsCountedPerSystem() throws {
        let report = Self.baseReport()
        let primary = try #require(report.system("qwen3")).protection
        #expect(primary.numeric == ASREvaluation.ClassHarmCount(total: 1, harmed: 0))
        #expect(primary.negation == ASREvaluation.ClassHarmCount(total: 2, harmed: 0))
        #expect(primary.protectedTerm == ASREvaluation.ClassHarmCount(total: 1, harmed: 0))
        let chinese = try #require(report.system("classic:zh-CN")).protection
        #expect(chinese.numeric == ASREvaluation.ClassHarmCount(total: 1, harmed: 1))
        #expect(chinese.negation == ASREvaluation.ClassHarmCount(total: 2, harmed: 1))
        #expect(chinese.protectedTerm == ASREvaluation.ClassHarmCount(total: 1, harmed: 0))
        let english = try #require(report.system("classic:en-US")).protection
        #expect(english.numeric == ASREvaluation.ClassHarmCount(total: 1, harmed: 1))
        #expect(english.negation == ASREvaluation.ClassHarmCount(total: 2, harmed: 2))
        #expect(english.protectedTerm == ASREvaluation.ClassHarmCount(total: 1, harmed: 1))
        #expect(report.utterances[1].protectedSpans.map { $0.kind } == [.protectedTerm, .numeric])
        let negationUtterance = report.utterances[2]
        #expect(negationUtterance.protectedSpans == [
            ASREvaluation.ProtectedSpan(kind: .negation, tokenStart: 1, tokenCount: 1, text: "不"),
        ])
        #expect(negationUtterance.score(for: "classic:zh-CN")?.harms == [
            ASREvaluation.ProtectedHarm(spanIndex: 0, observed: ""),
        ])
    }

    @Test func negationLexiconSkipsNonNegatingCompoundsAndDrugNames() {
        func negations(_ text: String) -> [String] {
            ASREvaluation.protectedSpans(in: MixedErrorRate.tokenize(text))
                .filter { $0.kind == .negation }
                .map { $0.text }
        }
        #expect(negations("阿莫西林非常好，是否性别特别").isEmpty)
        #expect(negations("我没有发热，不咳嗽，未见异常，无过敏史，否认胸痛，别吃") == ["没", "不", "未", "无", "否", "别"])
        #expect(negations("I don't have chest pain and never smoked; patient denies fever") == ["don't", "never", "denies"])
    }

    // MARK: - 急救（BR-012 词表）

    @Test func emergencyRecallAndFalseAlarmUseKeywordRules() throws {
        let report = Self.baseReport()
        let primary = try #require(report.system("qwen3")).emergency
        #expect(primary.positiveCount == 1)
        #expect(primary.positiveDetected == 1)
        #expect(primary.recall == 1)
        #expect(primary.positiveReferenceMatched == 1)
        // 「我没有胸痛」：词表不看否定（BR-012 宁误报勿漏报）——阴性对照的参考本身就会命中
        #expect(primary.negativeCount == 2)
        #expect(primary.negativeFlagged == 1)
        #expect(primary.falseAlarmRate == 0.5)
        #expect(primary.negativeReferenceMatched == 1)
        let english = try #require(report.system("classic:en-US")).emergency
        #expect(english.recall == 0)
        #expect(english.falseAlarmRate == 0)
        #expect(report.warnings.isEmpty)
    }

    @Test func emergencyPositiveWhoseReferenceMissesLexiconIsWarned() {
        let manifest = ASREvaluation.Manifest(utterances: [
            .init(utteranceID: "p1", audioPath: "p1.wav", reference: "我很好", tags: [.emergencyPositive]),
        ])
        let report = ASREvaluation.evaluate(manifest: manifest, runs: [])
        #expect(report.warnings == ["句 p1 标 emergencyPositive，但参考文本未命中急救词表（召回分母存疑）"])
        #expect(report.oracle == nil)
        #expect(report.oracleGains.isEmpty)
    }

    // MARK: - 延迟

    @Test func latencyUsesNearestRankPercentilesAndFirstRun() throws {
        let latencies = ["u1": 700.0, "u2": 100, "u3": 600, "u4": 200, "u5": 500, "u6": 300, "u7": 400]
        let report = ASREvaluation.evaluate(manifest: Self.manifest,
                                            runs: [Self.run("qwen3", Self.primaryHypotheses, latencies: latencies)])
        let latency = try #require(report.system("qwen3")).latency
        #expect(latency.sampleCount == 7)
        #expect(latency.p50 == 400)
        #expect(latency.p95 == 700)
        #expect(latency.maximum == 700)
        #expect(latency.first == 700)
        let ramp = (1...20).map { Double($0) }
        #expect(ASREvaluation.nearestRankPercentile(ramp, 0.5) == 10)
        #expect(ASREvaluation.nearestRankPercentile(ramp, 0.95) == 19)
        #expect(ASREvaluation.nearestRankPercentile([], 0.5) == nil)
    }

    // MARK: - 统计

    @Test func splitMix64MatchesReferenceVector() {
        var generator = ASREvaluation.SplitMix64(seed: 0)
        let outputs = [generator.next(), generator.next(), generator.next()]
        #expect(outputs == [0xE220_A839_7B1D_CDAF, 0x6E78_9E6A_A1B9_65F4, 0x06C4_5D18_8009_454F])
        var bounded = ASREvaluation.SplitMix64(seed: ASREvaluation.defaultBootstrapSeed)
        let draws = (0..<8).map { _ in bounded.nextIndex(below: 7) }
        #expect(draws == [2, 2, 1, 0, 6, 1, 5, 3])
    }

    @Test func pairedBootstrapIsDeterministicAndEnforcesMinimumIterations() throws {
        let observations = (0..<30).map { index in Self.observation(index % 3, index % 2, length: 10) }
        let first = try #require(ASREvaluation.pairedBootstrap(engineA: "a", engineB: "b", observations: observations,
                                                               iterations: 10, seed: 7))
        let second = try #require(ASREvaluation.pairedBootstrap(engineA: "a", engineB: "b", observations: observations,
                                                                iterations: 10, seed: 7))
        #expect(first == second)
        #expect(first.iterations == 10_000)
        #expect(close(first.meanDifference, 0.05))
        #expect(first.lower <= first.meanDifference && first.meanDifference <= first.upper)
        #expect(first.microLower <= first.microDifference && first.microDifference <= first.microUpper)
        #expect(ASREvaluation.pairedBootstrap(engineA: "a", engineB: "b", observations: []) == nil)
        // 换种子 = 换重采样流。格点数据（0.1 步长）的重采样均值落在粗网格上，分位数可能恰好不变，
        // 故用近连续的差值验证种子敏感性（已用同算法的 Python 复算核对）。
        let continuous = (0..<30).map { index -> ASREvaluation.PairedObservation in
            let errorsA: Int = index * 37 % 101
            let errorsB: Int = index * 53 % 97
            return Self.observation(errorsA, errorsB, length: 100)
        }
        let seven = try #require(ASREvaluation.pairedBootstrap(engineA: "a", engineB: "b", observations: continuous,
                                                               seed: 7))
        let eight = try #require(ASREvaluation.pairedBootstrap(engineA: "a", engineB: "b", observations: continuous,
                                                               seed: 8))
        #expect(seven.lower != eight.lower)
        #expect(seven.upper != eight.upper)
        #expect(seven.meanDifference == eight.meanDifference)
        #expect(eight.lower <= eight.meanDifference && eight.meanDifference <= eight.upper)
    }

    @Test func pairedBootstrapRecoversKnownConstantDifference() throws {
        let observations = (0..<40).map { _ in Self.observation(3, 1, length: 8) }
        let result = try #require(ASREvaluation.pairedBootstrap(engineA: "segmented", engineB: "continuous",
                                                                observations: observations))
        #expect(result.utteranceCount == 40)
        #expect(result.meanDifference == 0.25)
        #expect(result.lower == 0.25)
        #expect(result.upper == 0.25)
        #expect(result.microDifference == 0.25)
        #expect(result.microLower == 0.25)
        #expect(result.microUpper == 0.25)
    }

    @Test func pairedBootstrapSeparatesShiftFromNoise() throws {
        let shifted = (0..<40).map { index in Self.observation(2 + index % 3, 1, length: 10) }
        let shift = try #require(ASREvaluation.pairedBootstrap(engineA: "a", engineB: "b", observations: shifted))
        #expect(shift.lower > 0)
        let noisy = (0..<40).map { index -> ASREvaluation.PairedObservation in
            let errorsA: Int = index % 2 == 0 ? 2 : 0
            return Self.observation(errorsA, 1, length: 10)
        }
        let noise = try #require(ASREvaluation.pairedBootstrap(engineA: "a", engineB: "b", observations: noisy))
        #expect(noise.lower < 0)
        #expect(noise.upper > 0)
    }

    // MARK: - 置信度区分度（AUROC）

    @Test func aurocMatchesMannWhitneyWithHalfCreditTies() {
        func sample(_ confidence: Double, _ correct: Bool) -> ASREvaluation.ConfidenceSample {
            ASREvaluation.ConfidenceSample(confidence: confidence, isCorrect: correct)
        }
        let perfect = [sample(0.9, true), sample(0.8, true), sample(0.2, false), sample(0.1, false)]
        let reversed = [sample(0.1, true), sample(0.2, true), sample(0.8, false), sample(0.9, false)]
        let allTied = [sample(0.5, true), sample(0.5, false), sample(0.5, true)]
        let mixed = [sample(0.9, true), sample(0.6, true), sample(0.7, false), sample(0.2, false)]
        let partialTie = [sample(0.5, true), sample(0.5, false), sample(0.1, false)]
        #expect(ASREvaluation.confidenceAUROC(perfect) == 1)
        #expect(ASREvaluation.confidenceAUROC(reversed) == 0)
        #expect(ASREvaluation.confidenceAUROC(allTied) == 0.5)
        #expect(ASREvaluation.confidenceAUROC(mixed) == 0.75)
        #expect(ASREvaluation.confidenceAUROC(partialTie) == 0.75)
        #expect(ASREvaluation.confidenceAUROC([sample(0.9, true), sample(0.4, true)]) == nil)
        #expect(ASREvaluation.confidenceAUROC([sample(0.9, false)]) == nil)
        #expect(ASREvaluation.confidenceAUROC([]) == nil)
    }

    @Test func engineTokenConfidencesMapOntoMERTokens() {
        let mixed = ASREvaluation.tokenConfidences(hypothesis: "Yes，你说的很对", tokens: [
            TranscriptionToken(text: "Yes", confidence: 0.9), TranscriptionToken(text: "你说的", confidence: 0.6),
            TranscriptionToken(text: "很对"),
        ])
        #expect(mixed == [0.9, 0.6, 0.6, 0.6, nil, nil])
        // 词片拼成一个词：取最弱一片；大小写不敏感
        let pieces = ASREvaluation.tokenConfidences(hypothesis: "Amoxicillin 500mg", tokens: [
            TranscriptionToken(text: "amox", confidence: 0.9), TranscriptionToken(text: "icillin", confidence: 0.4),
            TranscriptionToken(text: "500", confidence: 0.8), TranscriptionToken(text: "mg", confidence: 0.7),
        ])
        #expect(pieces == [0.4, 0.8, 0.7])
        let unmatched = ASREvaluation.tokenConfidences(hypothesis: "500", tokens: [
            TranscriptionToken(text: "xyz", confidence: 0.1), TranscriptionToken(text: "500", confidence: 0.8),
        ])
        #expect(unmatched == [0.8])
    }

    @Test func reportComputesPerSystemAUROCFromTokenEvidence() throws {
        let separating = ASREvaluation.evaluate(manifest: Self.manifest, runs: [Self.confidentRun("qwen3", wrongWordConfidence: 0.30)])
        let confidence = try #require(separating.system("qwen3")).confidence
        #expect(confidence.sampleCount == 39)
        #expect(confidence.incorrectCount == 1)
        #expect(confidence.auroc == 1)
        let inverted = ASREvaluation.evaluate(manifest: Self.manifest, runs: [Self.confidentRun("qwen3", wrongWordConfidence: 0.99)])
        #expect(inverted.system("qwen3")?.confidence.auroc == 0)
        let flat = ASREvaluation.evaluate(manifest: Self.manifest, runs: [Self.confidentRun("qwen3", wrongWordConfidence: 0.95)])
        #expect(flat.system("qwen3")?.confidence.auroc == 0.5)
        #expect(Self.baseReport().system("qwen3")?.confidence == ASREvaluation.ConfidenceDiscrimination.empty)
    }

    // MARK: - harm/fix（参考锚定，相对主轨）

    @Test func harmFixCountsTokenFixesAndHarmsAgainstReference() {
        // 「不」：主轨删、候选对 → fix；「热」：主轨对、候选错 → harm
        let swap = ASREvaluation.harmFix(reference: "我不发热", primary: "我发热", candidate: "我不发烧")
        #expect(swap.tokenFixes == 1)
        #expect(swap.tokenHarms == 1)
        #expect(swap.fixes == 1)
        #expect(swap.harms == 1)
        #expect(swap.harmFixRatio == 1)
        #expect(swap.exceeds(0.2))
        let same = ASREvaluation.harmFix(reference: "我不发热", primary: "我发热", candidate: "我发热")
        #expect(same.fixes == 0)
        #expect(same.harms == 0)
        #expect(same.harmFixRatio == nil)
        #expect(!same.exceeds(0.2))
        let onlyHarm = ASREvaluation.harmFix(reference: "我不发热", primary: "我不发热", candidate: "我发热")
        #expect(onlyHarm.harmFixRatio == nil)
        #expect(onlyHarm.exceeds(0.2))
    }

    @Test func harmFixCountsInsertionsPerReferenceGap() {
        // 主轨多出「嗯」（候选去掉 → fix），候选新增「了」（→ harm）
        let result = ASREvaluation.harmFix(reference: "今天血压正常", primary: "嗯今天血压正常", candidate: "今天血压正常了")
        #expect(result.tokenFixes == 0)
        #expect(result.tokenHarms == 0)
        #expect(result.insertionFixes == 1)
        #expect(result.insertionHarms == 1)
        #expect(result.harmFixRatio == 1)
        let fixesOnly = ASREvaluation.harmFix(reference: "take one tablet", primary: "take one table",
                                              candidate: "take one tablet")
        #expect(fixesOnly.fixes == 1)
        #expect(fixesOnly.harms == 0)
        #expect(fixesOnly.harmFixRatio == 0)
    }

    @Test func reportHarmFixAccumulatesOverScoredUtterances() throws {
        var fusion = Self.primaryHypotheses
        fusion["u7"] = "take one tablet"
        fusion["u1"] = "Yes，你说的很队"
        fusion["u5"] = "今天天气很号"
        let report = ASREvaluation.evaluate(manifest: Self.manifest, runs: [
            Self.run("qwen3", Self.primaryHypotheses), Self.run("fusion:v1", fusion),
        ])
        let harmFix = try #require(ASREvaluation.harmFix(report: report, primaryEngineID: "qwen3",
                                                         candidateEngineID: "fusion:v1"))
        #expect(harmFix.utteranceCount == 7)
        #expect(harmFix.fixes == 1)
        #expect(harmFix.harms == 2)
        #expect(harmFix.harmFixRatio == 2)
        #expect(ASREvaluation.harmFix(report: report, primaryEngineID: "qwen3", candidateEngineID: "missing") == nil)
    }

    // MARK: - 止损判定：规则 1（Apple-en）

    @Test func verdictTreatsSentenceLevelOracleAsAdvisoryOnly() throws {
        var english = Self.appleEnglishHypotheses
        english["u7"] = "take one table"
        let report = ASREvaluation.evaluate(manifest: Self.manifest, runs: [
            Self.run("qwen3", Self.primaryHypotheses), Self.run("classic:zh-CN", Self.appleChineseHypotheses),
            Self.run("classic:en-US", english),
        ])
        #expect(report.oracleGain(of: "classic:en-US")?.microGainPercentagePoints == 0)
        let verdict = ASREvaluationVerdict.evaluate(report: report, configuration: .init(
            primaryEngineID: "qwen3", appleEnglishEngineID: "classic:en-US"))
        let finding = try #require(verdict.finding(.appleEnglishMarginalGain))
        // 逐句增益 0.00pt 也不得据此删除：只出「证据不足（advisory）」
        #expect(finding.status == .advisory)
        #expect(finding.action == .awaitTokenLevelEvidence)
        #expect(finding.reasons.first?.contains("证据不足（advisory），不建议删除") == true)
        #expect(finding.reasons.last?.contains("逐句 oracle 增益 0.00 个百分点") == true)
    }

    @Test func verdictDecidesAppleEnglishOnlyFromTokenLevelEvidence() throws {
        let report = Self.baseReport()
        func finding(_ evidence: ASREvaluationVerdict.TokenLevelEvidence) throws -> ASREvaluationVerdict.Finding {
            let verdict = ASREvaluationVerdict.evaluate(report: report, configuration: .init(
                primaryEngineID: "qwen3", appleEnglishEngineID: "classic:en-US", appleEnglishTokenLevelEvidence: evidence))
            return try #require(verdict.finding(.appleEnglishMarginalGain))
        }
        func evidence(gain: Double, lower: Double?, harms: Int?, fixes: Int?,
                      languageFromPrimary: Bool = true) -> ASREvaluationVerdict.TokenLevelEvidence {
            ASREvaluationVerdict.TokenLevelEvidence(gainPercentagePoints: gain, gainLowerBoundPercentagePoints: lower,
                                                    harms: harms, fixes: fixes, languageFromPrimary: languageFromPrimary,
                                                    source: "fusion:v1 消融")
        }
        let keep = try finding(evidence(gain: 0.90, lower: 0.12, harms: 1, fixes: 10))
        #expect(keep.status == .passed)
        #expect(keep.action == .keepAppleEnglish)
        #expect(keep.reasons.first?.contains("token 级边际增益 +0.90 个百分点（95% CI 下界 +0.12；harm/fix 1/10；fusion:v1 消融）") == true)
        let insignificant = try finding(evidence(gain: 0.90, lower: -0.20, harms: 1, fixes: 10))
        #expect(insignificant.status == .triggered)
        #expect(insignificant.action == .dropAppleEnglish)
        let harmful = try finding(evidence(gain: 1.90, lower: 0.40, harms: 3, fixes: 10))
        #expect(harmful.action == .dropAppleEnglish)
        #expect(harmful.reasons.first?.contains("harm/fix 3/10 > 0.20") == true)
        let noInterval = try finding(evidence(gain: 1.90, lower: nil, harms: 0, fixes: 10))
        #expect(noInterval.action == .dropAppleEnglish)
        let leaked = try finding(evidence(gain: 1.90, lower: 0.40, harms: 0, fixes: 10, languageFromPrimary: false))
        #expect(leaked.status == .advisory)
        #expect(leaked.action == .awaitTokenLevelEvidence)
        let invalid = try finding(evidence(gain: .nan, lower: 0.40, harms: 0, fixes: 10))
        #expect(invalid.status == .advisory)
    }

    @Test func fusionAblationEvidenceIsComputedFromReportSystems() throws {
        let primary = Self.englishRun("qwen3") { _ in "take one table" }
        let withoutEnglish = Self.englishRun("fusion:without-en") { _ in "take one table" }
        let cleanWithEnglish = Self.englishRun("fusion:with-en") { _ in "take one tablet" }
        let clean = ASREvaluation.evaluate(manifest: Self.englishManifest,
                                           runs: [primary, withoutEnglish, cleanWithEnglish])
        let evidence = try #require(ASREvaluationVerdict.TokenLevelEvidence.fusionAblation(
            report: clean, primaryEngineID: "qwen3", withEngineID: "fusion:with-en",
            withoutEngineID: "fusion:without-en", languageFromPrimary: true))
        #expect(close(evidence.gainPercentagePoints, 100.0 / 3.0))
        #expect(close(evidence.gainLowerBoundPercentagePoints, 100.0 / 3.0))
        #expect(evidence.harms == 0)
        #expect(evidence.fixes == 20)
        let kept = ASREvaluationVerdict.evaluate(report: clean, configuration: .init(
            primaryEngineID: "qwen3", appleEnglishEngineID: "classic:en-US", appleEnglishTokenLevelEvidence: evidence))
        #expect(kept.finding(.appleEnglishMarginalGain)?.action == .keepAppleEnglish)

        // 含 Apple-en 后半数句把「one」改坏：harm/fix = 10/20 > 0.2 → 删除
        let noisyWithEnglish = Self.englishRun("fusion:with-en") { index in
            index % 2 == 0 ? "take one tablet" : "take won tablet"
        }
        let noisy = ASREvaluation.evaluate(manifest: Self.englishManifest,
                                           runs: [primary, withoutEnglish, noisyWithEnglish])
        let noisyEvidence = try #require(ASREvaluationVerdict.TokenLevelEvidence.fusionAblation(
            report: noisy, primaryEngineID: "qwen3", withEngineID: "fusion:with-en",
            withoutEngineID: "fusion:without-en", languageFromPrimary: true))
        #expect(noisyEvidence.harms == 10)
        #expect(noisyEvidence.fixes == 20)
        let dropped = ASREvaluationVerdict.evaluate(report: noisy, configuration: .init(
            primaryEngineID: "qwen3", appleEnglishTokenLevelEvidence: noisyEvidence))
        #expect(dropped.finding(.appleEnglishMarginalGain)?.action == .dropAppleEnglish)
        #expect(ASREvaluationVerdict.TokenLevelEvidence.fusionAblation(
            report: noisy, primaryEngineID: "qwen3", withEngineID: "fusion:with-en",
            withoutEngineID: "missing", languageFromPrimary: true) == nil)
    }

    @Test func verdictSentenceNoteExcludesCandidatesFromPoolAndContinues() throws {
        var fusion = Self.primaryHypotheses
        fusion["u7"] = "take one tablet"
        let report = ASREvaluation.evaluate(manifest: Self.manifest,
                                            runs: Self.baseRuns() + [Self.run("fusion:v1", fusion)])
        // 融合系统进池会把 Apple-en 的逐句增益吃掉；参考信息只看单模池
        #expect(report.oracleGain(of: "classic:en-US")?.microGainPercentagePoints == 0)
        let verdict = ASREvaluationVerdict.evaluate(report: report, configuration: .init(
            primaryEngineID: "qwen3", appleEnglishEngineID: "classic:en-US", candidateEngineIDs: ["fusion:v1"]))
        let finding = try #require(verdict.finding(.appleEnglishMarginalGain))
        #expect(finding.status == .advisory)
        #expect(finding.reasons.last?.contains("逐句 oracle 增益 2.56 个百分点") == true)
        #expect(verdict.finding(.safetyRegression)?.status == .passed)
        #expect(verdict.decision == .continue)
    }

    // MARK: - 止损判定：规则 2（切段 vs 连续）

    @Test func verdictSkipsSameSegmentDecodingWhenSegmentedSignificantlyWorse() throws {
        let report = ASREvaluation.evaluate(manifest: Self.manifest, runs: Self.baseRuns() + [
            Self.run("classic:zh-CN#segmented", Self.segmentedHypotheses),
        ])
        let verdict = ASREvaluationVerdict.evaluate(report: report, configuration: .init(
            primaryEngineID: "qwen3", segmentedEngineID: "classic:zh-CN#segmented", continuousEngineID: "classic:zh-CN"))
        let finding = try #require(verdict.finding(.segmentedVersusContinuous))
        #expect(finding.status == .triggered)
        #expect(finding.action == .skipSameSegmentDecoding)
        let bootstrap = try #require(verdict.segmentedVersusContinuous)
        #expect(bootstrap.engineA == "classic:zh-CN#segmented")
        #expect(bootstrap.utteranceCount == 7)
        #expect(bootstrap.iterations == 10_000)
        #expect(bootstrap.lower > 0)
    }

    @Test func verdictAllowsSameSegmentDecodingWhenNotSignificantlyWorse() throws {
        let report = ASREvaluation.evaluate(manifest: Self.manifest, runs: Self.baseRuns() + [
            Self.run("classic:zh-CN#segmented", Self.appleChineseHypotheses),
        ])
        let verdict = ASREvaluationVerdict.evaluate(report: report, configuration: .init(
            primaryEngineID: "qwen3", segmentedEngineID: "classic:zh-CN#segmented", continuousEngineID: "classic:zh-CN"))
        let finding = try #require(verdict.finding(.segmentedVersusContinuous))
        #expect(finding.status == .passed)
        #expect(finding.action == .allowSameSegmentDecoding)
        #expect(verdict.segmentedVersusContinuous?.lower == 0)
    }

    // MARK: - 止损判定：规则 3（急救/否定回归）

    @Test func verdictStopsOnEmergencyOrNegationRegression() throws {
        var fusion = Self.primaryHypotheses
        fusion["u3"] = "我发热"
        fusion["u4"] = "我胸通得厉害"
        let report = ASREvaluation.evaluate(manifest: Self.manifest, runs: [
            Self.run("qwen3", Self.primaryHypotheses), Self.run("fusion:v1", fusion),
        ])
        let verdict = ASREvaluationVerdict.evaluate(report: report, configuration: .init(
            primaryEngineID: "qwen3", candidateEngineIDs: ["fusion:v1"]))
        #expect(verdict.decision == .stop)
        #expect(!verdict.automaticRewriteAllowed)
        let finding = try #require(verdict.finding(.safetyRegression))
        #expect(finding.status == .triggered)
        #expect(finding.action == .terminateFusion)
        #expect(verdict.regressions == [
            ASREvaluationVerdict.Regression(candidateEngineID: "fusion:v1", emergencyPairs: 1,
                                            lostEmergencyUtteranceIDs: ["u4"], negationSpans: 2,
                                            lostNegationSpans: 1, lostNegationUtteranceIDs: ["u3"]),
        ])
    }

    @Test func verdictIgnoresHarmThePrimaryAlreadyHad() throws {
        var primary = Self.primaryHypotheses
        primary["u3"] = "我发热"
        var fusion = primary
        fusion["u7"] = "take one tablet"
        let report = ASREvaluation.evaluate(manifest: Self.manifest, runs: [
            Self.run("qwen3", primary), Self.run("fusion:v1", fusion),
        ])
        let verdict = ASREvaluationVerdict.evaluate(report: report, configuration: .init(
            primaryEngineID: "qwen3", candidateEngineIDs: ["fusion:v1"]))
        #expect(verdict.decision == .continue)
        #expect(verdict.finding(.safetyRegression)?.action == .continueFusion)
        #expect(verdict.regressions.first?.lostNegationSpans == 0)
        #expect(verdict.regressions.first?.hasEvidence == true)
    }

    // MARK: - 止损判定：规则 4（harm/fix）与规则 5（AUROC）

    @Test func verdictForbidsAutomaticRewriteWhenHarmFixExceedsLimit() throws {
        var harmful = Self.primaryHypotheses
        harmful["u7"] = "take one tablet"
        harmful["u1"] = "Yes，你说的很队"
        harmful["u5"] = "今天天气很号"
        let report = ASREvaluation.evaluate(manifest: Self.manifest, runs: [
            Self.run("qwen3", Self.primaryHypotheses), Self.run("fusion:v1", harmful),
        ])
        let verdict = ASREvaluationVerdict.evaluate(report: report, configuration: .init(
            primaryEngineID: "qwen3", candidateEngineIDs: ["fusion:v1"]))
        let finding = try #require(verdict.finding(.harmFixRatio))
        #expect(finding.status == .triggered)
        #expect(finding.action == .forbidAutomaticRewrite)
        #expect(verdict.harmFixByCandidate.first?.harms == 2)
        #expect(verdict.harmFixByCandidate.first?.fixes == 1)
        #expect(!verdict.automaticRewriteAllowed)

        let unchanged = ASREvaluation.evaluate(manifest: Self.manifest, runs: [
            Self.run("qwen3", Self.primaryHypotheses), Self.run("fusion:v1", Self.primaryHypotheses),
        ])
        let idle = ASREvaluationVerdict.evaluate(report: unchanged, configuration: .init(
            primaryEngineID: "qwen3", candidateEngineIDs: ["fusion:v1"]))
        #expect(idle.finding(.harmFixRatio)?.status == .notEvaluated)
        #expect(idle.finding(.harmFixRatio)?.action == .forbidAutomaticRewrite)
    }

    @Test func verdictKeepsDisagreementHintsOnlyWhenNoConfidenceSourceDiscriminates() throws {
        var fusion = Self.primaryHypotheses
        fusion["u7"] = "take one tablet"
        func verdict(_ wrongWordConfidence: Double) -> ASREvaluationVerdict {
            let report = ASREvaluation.evaluate(manifest: Self.manifest, runs: [
                Self.confidentRun("qwen3", wrongWordConfidence: wrongWordConfidence), Self.run("fusion:v1", fusion),
            ])
            return ASREvaluationVerdict.evaluate(report: report, configuration: .init(
                primaryEngineID: "qwen3", candidateEngineIDs: ["fusion:v1"]))
        }
        let flat = verdict(0.95)
        #expect(flat.finding(.confidenceDiscrimination)?.status == .triggered)
        #expect(flat.finding(.confidenceDiscrimination)?.action == .disagreementHintsOnly)
        #expect(!flat.automaticRewriteAllowed)
        let sharp = verdict(0.30)
        #expect(sharp.finding(.confidenceDiscrimination)?.status == .passed)
        #expect(sharp.finding(.confidenceDiscrimination)?.action == .allowTokenLevelRewrite)
        #expect(sharp.finding(.harmFixRatio)?.status == .passed)
        #expect(sharp.decision == .continue)
        #expect(sharp.automaticRewriteAllowed)
        // 两个置信源：任一 ≥ 0.85 即可
        let mixedSources = ASREvaluation.evaluate(manifest: Self.manifest, runs: [
            Self.confidentRun("qwen3", wrongWordConfidence: 0.95), Self.confidentRun("sherpa:zipformer", wrongWordConfidence: 0.30),
        ])
        let mixedVerdict = ASREvaluationVerdict.evaluate(report: mixedSources, configuration: .init(primaryEngineID: "qwen3"))
        #expect(mixedVerdict.finding(.confidenceDiscrimination)?.status == .passed)
        #expect(ASREvaluationVerdict.Thresholds.minimumConfidenceAUROC == 0.85)
        #expect(ASREvaluationVerdict.Thresholds.maximumHarmFixRatio == 0.2)
    }

    @Test func verdictFailsClosedWhenEvidenceIsMissing() throws {
        let bare = ASREvaluationVerdict.evaluate(report: Self.baseReport(), configuration: .init(
            primaryEngineID: "qwen3", appleEnglishEngineID: "classic:fr-FR"))
        #expect(bare.decision == .stop)
        #expect(!bare.automaticRewriteAllowed)
        // 规则 1 缺 token 级证据只出 advisory（删除引擎本身需要证据）；规则 2–5 按 fail-closed 取保守动作
        #expect(bare.findings.map { $0.status } == [.advisory, .notEvaluated, .notEvaluated, .notEvaluated, .notEvaluated])
        #expect(bare.findings.map { $0.action } == [
            .awaitTokenLevelEvidence, .skipSameSegmentDecoding, .terminateFusion, .forbidAutomaticRewrite,
            .disagreementHintsOnly,
        ])

        let skippedCandidate = ASREvaluation.evaluate(manifest: Self.manifest, runs: [
            Self.run("qwen3", Self.primaryHypotheses), .skipped("fusion:v1", reason: "未授权"),
        ])
        let skipped = ASREvaluationVerdict.evaluate(report: skippedCandidate, configuration: .init(
            primaryEngineID: "qwen3", candidateEngineIDs: ["fusion:v1"]))
        #expect(skipped.decision == .stop)
        #expect(skipped.finding(.safetyRegression)?.reasons.first?.contains("已跳过：未授权") == true)

        let withoutNegation = ASREvaluation.Manifest(utterances: Self.manifest.utterances.filter { !$0.has(.negation) })
        let thin = ASREvaluation.evaluate(manifest: withoutNegation, runs: [
            Self.run("qwen3", Self.primaryHypotheses), Self.run("fusion:v1", Self.primaryHypotheses),
        ])
        let thinVerdict = ASREvaluationVerdict.evaluate(report: thin, configuration: .init(
            primaryEngineID: "qwen3", candidateEngineIDs: ["fusion:v1"]))
        #expect(thinVerdict.finding(.safetyRegression)?.status == .notEvaluated)
        #expect(thinVerdict.decision == .stop)
    }

    // MARK: - 急救样本量（零事件法则）

    @Test func zeroEventUpperBoundFollowsExactRuleOfThree() {
        let twenty = ASREvaluationVerdict.zeroEventMissRateUpperBound(samples: 20)
        #expect(abs(twenty - 0.1391) < 1e-3)
        #expect(twenty < 3.0 / 20)
        #expect(abs(ASREvaluationVerdict.zeroEventMissRateUpperBound(samples: 60) - 0.0487) < 1e-3)
        #expect(ASREvaluationVerdict.zeroEventMissRateUpperBound(samples: 0) == 1)
        #expect(ASREvaluationVerdict.Thresholds.minimumEmergencyPositiveSamples == 60)
    }

    @Test func smallEmergencySampleCanOnlyDetectRegressions() throws {
        var fusion = Self.primaryHypotheses
        fusion["u7"] = "take one tablet"
        let report = ASREvaluation.evaluate(manifest: Self.manifest, runs: [
            Self.run("qwen3", Self.primaryHypotheses), Self.run("fusion:v1", fusion),
        ])
        let verdict = ASREvaluationVerdict.evaluate(report: report, configuration: .init(
            primaryEngineID: "qwen3", candidateEngineIDs: ["fusion:v1"]))
        // 零回归 → continue，但 n=1 的急救结论不能当作「安全已证明」
        #expect(verdict.decision == .continue)
        #expect(verdict.emergencySampleAdequacy.positiveSamples == 1)
        #expect(verdict.emergencySampleAdequacy.canOnlyDetectRegressions)
        #expect(abs(verdict.emergencySampleAdequacy.missRateUpperBound - 0.95) < 1e-12)
        #expect(verdict.finding(.safetyRegression)?.reasons.last
            == "急救阳性样本 n=1 < 60：急救结论只能发现回归、不能证明安全（零漏报时漏报率 95% 置信上限 ≈ 95.0%）")
    }

    @Test func sixtyEmergencyPositivesLiftTheSafetyCaveat() throws {
        let positives = (0..<60).map { index -> ASREvaluation.Utterance in
            ASREvaluation.Utterance(utteranceID: "e\(index)", audioPath: "e\(index).wav", reference: "我胸痛得厉害",
                                    tags: [.emergencyPositive])
        }
        let negation = ASREvaluation.Utterance(utteranceID: "n1", audioPath: "n1.wav", reference: "我不发热",
                                               tags: [.negation])
        let manifest = ASREvaluation.Manifest(utterances: positives + [negation])
        let results = manifest.utterances.map { utterance -> ASREvaluation.UtteranceResult in
            ASREvaluation.UtteranceResult.recognized(utterance.utteranceID, hypothesis: utterance.reference)
        }
        let report = ASREvaluation.evaluate(manifest: manifest, runs: [
            ASREvaluation.SystemRun(engineID: "qwen3", results: results),
            ASREvaluation.SystemRun(engineID: "fusion:v1", results: results),
        ])
        let verdict = ASREvaluationVerdict.evaluate(report: report, configuration: .init(
            primaryEngineID: "qwen3", candidateEngineIDs: ["fusion:v1"]))
        #expect(verdict.decision == .continue)
        #expect(verdict.emergencySampleAdequacy.positiveSamples == 60)
        #expect(!verdict.emergencySampleAdequacy.canOnlyDetectRegressions)
        #expect(verdict.finding(.safetyRegression)?.reasons.last
            == "急救阳性样本 n=60 ≥ 60（零漏报时漏报率 95% 置信上限 ≈ 4.9%）")
    }

    // MARK: - 渲染

    @Test func renderingIsStableAndRoundTrips() throws {
        let latencies = ["u1": 700.0, "u2": 100, "u3": 600, "u4": 200, "u5": 500, "u6": 300, "u7": 400]
        let report = ASREvaluation.evaluate(manifest: Self.manifest, runs: Self.baseRuns(primaryLatencies: latencies) + [
            .skipped("classic:yue-HK", reason: "该 locale 不支持端侧识别"),
        ])
        let verdict = ASREvaluationVerdict.evaluate(report: report, configuration: .init(
            primaryEngineID: "qwen3", appleEnglishEngineID: "classic:en-US"))
        let json = try ASREvaluationRendering.json(report: report, verdict: verdict)
        let again = try ASREvaluationRendering.json(report: report, verdict: verdict)
        #expect(json == again)
        let decoded = try ASREvaluationRendering.decodeDocument(from: json)
        #expect(decoded == ASREvaluationRendering.Document(report: report, verdict: verdict))

        let markdown = ASREvaluationRendering.markdown(report: report, verdict: verdict)
        #expect(ASREvaluationRendering.markdown(report: report, verdict: verdict) == markdown)
        let lines = markdown.components(separatedBy: "\n")
        #expect(lines.first == "# ASR 杀手实验评测报告")
        #expect(lines.contains("- 句数：7（mixed 1 · numeric 1 · negation 2 · drug 1 · emergencyPositive 1 · emergencyNegative 2）"))
        #expect(lines.contains(
            "| qwen3 | 7/0/0 | 2.56% | 4.76% | 1/0/0 | 0/1 | 0/2 | 0/1 | 1/1 (100.00%) | 1/2 (50.00%) | — | 400/700/700 | — |"))
        #expect(lines.contains(
            "| classic:yue-HK | 已跳过：该 locale 不支持端侧识别 | — | — | — | — | — | — | — | — | — | — | — |"))
        #expect(lines.contains("| classic:zh-CN | 33.33% (1) | 22.22% (1) | 11.11% (2) | 22.22% (1) | 0.00% (1) | 0.00% (2) |"))
        #expect(lines.contains("- oracle MER：micro 0.00% · macro 0.00%（7 句）"))
        #expect(lines.contains("| classic:en-US | 2.56% | 0.00% | 2.56 | 4.76 | 7 |"))
        #expect(lines.contains("## 止损判定：**stop（止损：终止多模融合）**"))
        #expect(lines.contains { $0.hasPrefix("| Apple-en 边际增益 | 证据不足（advisory） | 暂不删除（待 token 级证据） |") })
        #expect(lines.contains { $0.hasPrefix("| 置信度区分度 AUROC | 未评估 | 只保留不一致提示 |") })
        #expect(lines.contains("- 自动改写：不放行（只保留不一致提示 / 候选点选）"))
        #expect(lines.contains(
            "- 急救样本量：急救阳性样本 n=1 < 60：急救结论只能发现回归、不能证明安全（零漏报时漏报率 95% 置信上限 ≈ 95.0%）"))
        // Markdown 只有指标，不带参考/假设原文
        #expect(!markdown.contains("你说的很对"))
    }

    @Test func fixedFormattingNeverRendersNegativeZero() {
        #expect(ASREvaluation.formatFixed(-0.0001, digits: 2) == "0.00")
        #expect(ASREvaluation.formatSigned(0.0001, digits: 2) == "0.00")
        #expect(ASREvaluation.formatSigned(1.234, digits: 2) == "+1.23")
        #expect(ASREvaluation.formatSigned(-1.234, digits: 2) == "-1.23")
        #expect(ASREvaluation.formatPercent(nil) == "—")
        #expect(ASREvaluation.formatPercent(0.123456) == "12.35%")
    }
}
