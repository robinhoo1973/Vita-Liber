import Foundation
import Testing
@testable import Domain

// binds: SU-M15-ASREVIDENCE — 识别证据面纯换算（round3 P0-B §8-1）：sherpa 词元清洗与拼字、log 概率→置信度、
// 段偏移、Apple 词段、n-best 整理、会话词元上限、置信度性质诚实判定、在线结果 JSON 段起点
/// 引擎适配层（平台守卫，Linux 零编译信号）只把原生对象读成数组；这里钉住全部换算规则：
/// 缺就是 nil、错位整列弃用、不推断、不补常数，交付文本永远不被证据改动。
@Suite("SU-M15-ASREVIDENCE · 识别证据面（逐词时间/置信度/n-best 诚实回传）")
struct TranscriptionTokenAssemblyTests {

    private func utf8(_ pieces: [String]) -> [[UInt8]] { pieces.map { Array($0.utf8) } }

    private func near(_ value: Double?, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance
    }

    private func near(_ values: [Double?], _ expected: [Double]) -> Bool {
        values.count == expected.count && zip(values, expected).allSatisfy { near($0, $1) }
    }

    // MARK: - sherpa 词元清洗

    @Test func sentencePiecePrefixIsStrippedAndBareBoundaryDropped() {
        let tokens = TranscriptionTokenAssembly.sherpaTokens(utf8(["▁HELLO", "▁", "WOR", "LD", "你"]),
                                                            timestamps: [0.0, 0.2, 0.3, 0.4, 0.6])
        #expect(tokens.map(\.text) == ["HELLO", "WOR", "LD", "你"], "单独的 ▁ 是词界不是内容")
        #expect(tokens.map(\.start) == [0.0, 0.3, 0.4, 0.6], "丢弃 ▁ 后其余词元仍取自己的时间，不错位")
    }

    @Test func specialSymbolsAndLanguageTagsNeverBecomeTokens() {
        let tokens = TranscriptionTokenAssembly.sherpaTokens(utf8(["<unk>", "<|zh|>", "<blk>", "</s>", "好"]))
        #expect(tokens.map(\.text) == ["好"])
        #expect(TranscriptionTokenAssembly.cleanedText("<|NEUTRAL|>") == nil)
        #expect(TranscriptionTokenAssembly.cleanedText("<b>") == "<b>", "只认已知特殊符号与 <|…|> 标签，不误伤普通文本")
    }

    @Test func qwenStyleDecodedPiecesAreTrimmedAndPlaceholdersSkipped() {
        // Qwen3：GetTokenStringStreaming 已解码；半字占位为空串，残留字节以 U+FFFD 收尾。
        let tokens = TranscriptionTokenAssembly.sherpaTokens(utf8([" hello", "", "你好", " world\u{FFFD}"]))
        #expect(tokens.map(\.text) == ["hello", "你好", "world"])
        #expect(tokens.allSatisfy { $0.start == nil && $0.confidence == nil }, "Qwen3 不给时间与置信度，不得补")
        #expect(TranscriptionTokenAssembly.confidenceKind(of: tokens) == .unavailable)
    }

    // MARK: - 拼字（字节回退 / 字节级 BPE）

    @Test func byteFallbackPiecesMergeIntoOneCharacterWithChainRuleConfidence() {
        let tokens = TranscriptionTokenAssembly.sherpaTokens(
            utf8(["<0xE4>", "<0xBD>", "<0xA0>", "好"]),
            timestamps: [1.0, 1.04, 1.08, 1.2],
            logProbabilities: [log(0.9), log(0.8), log(0.5), log(0.7)])
        #expect(tokens.map(\.text) == ["你", "好"])
        #expect(tokens.first?.start == 1.0, "拼成的字取首片起点")
        #expect(near(tokens.first?.confidence, 0.9 * 0.8 * 0.5), "整字概率 = 各片概率之积（链式法则）")
        #expect(near(tokens.last?.confidence, 0.7))
    }

    @Test func rawSplitBytesMergeAcrossTokensAndDurationsSum() {
        // whisper 字节级 BPE：「你好」= E4 BD A0 | E5 A5 BD，被切在三个词元里。
        let tokens = TranscriptionTokenAssembly.sherpaTokens([[0xE4, 0xBD], [0xA0, 0xE5, 0xA5], [0xBD]],
                                                            timestamps: [0.5, 0.7, 0.9], durations: [0.1, 0.2, 0.3])
        #expect(tokens.map(\.text) == ["你好"])
        #expect(tokens.first?.start == 0.5)
        #expect(near(tokens.first?.duration, 0.6))
    }

    @Test func emptyPlaceholderBetweenSplitBytesContributesNoEvidence() {
        // 拼回字符时只允许并入真正参与拼接的原始下标；空占位的时长/概率不得算进来。
        let tokens = TranscriptionTokenAssembly.sherpaTokens(
            [[0xE4, 0xBD], [], [0xA0]],
            timestamps: [0.5, 0.7, 0.9],
            durations: [0.1, 5.0, 0.3],
            logProbabilities: [log(0.9), log(0.5), log(0.8)])
        #expect(tokens.map(\.text) == ["你"])
        #expect(near(tokens.first?.duration, 0.4))
        #expect(near(tokens.first?.confidence, 0.72))
    }

    @Test func fourByteCharacterSplitInHalfIsReassembled() {
        let tokens = TranscriptionTokenAssembly.sherpaTokens([[0xF0, 0x9F], [0x98, 0x80], Array("ok".utf8)])
        #expect(tokens.map(\.text) == ["😀", "ok"])
    }

    @Test func truncatedTailIsRepairedNotFabricated() {
        let tokens = TranscriptionTokenAssembly.sherpaTokens([[0x41], [0xE4, 0xBD]])
        #expect(tokens.map(\.text) == ["A"], "写了一半的字没有补齐就丢弃，不猜")
    }

    @Test func invalidLeadByteDoesNotSwallowFollowingTokens() {
        let tokens = TranscriptionTokenAssembly.sherpaTokens([[0xE4], [0x41], [0x42]])
        #expect(tokens.map(\.text) == ["A", "B"], "坏字节修成 U+FFFD 后清掉，后续词元照常成词")
    }

    @Test func incompleteTailDetectionCoversEveryLeadClass() {
        #expect(TranscriptionTokenAssembly.endsWithIncompleteUTF8([0xC3]))
        #expect(!TranscriptionTokenAssembly.endsWithIncompleteUTF8([0xC3, 0xA9]))
        #expect(TranscriptionTokenAssembly.endsWithIncompleteUTF8([0x41, 0xE4, 0xBD]))
        #expect(TranscriptionTokenAssembly.endsWithIncompleteUTF8([0xF0, 0x9F, 0x98]))
        #expect(!TranscriptionTokenAssembly.endsWithIncompleteUTF8([0x80, 0x80]), "只有续字节 = 非法，不是未完")
        #expect(!TranscriptionTokenAssembly.endsWithIncompleteUTF8([]))
        #expect(TranscriptionTokenAssembly.byteFallbackValue(Array("<0xe4>".utf8)) == 0xE4)
        #expect(TranscriptionTokenAssembly.byteFallbackValue(Array("<0xG4>".utf8)) == nil)
        #expect(TranscriptionTokenAssembly.byteFallbackValue(Array("<0x+4>".utf8)) == nil)
    }

    // MARK: - log 概率 → 置信度

    @Test func logProbabilityMapsThroughExpAndClamps() {
        #expect(TranscriptionTokenAssembly.confidence(logProbability: 0) == 1)
        #expect(near(TranscriptionTokenAssembly.confidence(logProbability: log(0.25)), 0.25))
        #expect(TranscriptionTokenAssembly.confidence(logProbability: -.infinity) == 0, "-∞ 是引擎给出的零概率")
        #expect(TranscriptionTokenAssembly.confidence(logProbability: .nan) == nil)
        #expect(TranscriptionTokenAssembly.confidence(logProbability: .infinity) == nil)
        #expect(TranscriptionTokenAssembly.confidence(logProbability: 0.3) == 1, "数值误差造成的正值夹到 1")
        #expect(TranscriptionTokenAssembly.confidence(logProbability: nil) == nil)
        #expect(TranscriptionTokenAssembly.confidence(.nan) == nil, "非有限原生置信度是未知，不是 0")
        #expect(TranscriptionTokenAssembly.confidence(1.7) == 1)
    }

    @Test func nanPieceMakesMergedConfidenceUnknown() {
        let tokens = TranscriptionTokenAssembly.sherpaTokens([[0xE4], [0xBD], [0xA0]],
                                                            logProbabilities: [log(0.9), .nan, log(0.9)])
        #expect(tokens.map(\.text) == ["你"])
        #expect(tokens.first?.confidence == nil)
    }

    // MARK: - NULL / 空 / 长度不一致 / 负时间 / 偏移

    @Test func nullArraysYieldTokensWithoutEvidenceNumbers() {
        let tokens = TranscriptionTokenAssembly.sherpaTokens(utf8(["你", "好"]))
        #expect(tokens.map(\.text) == ["你", "好"])
        #expect(tokens.allSatisfy { $0.start == nil && $0.duration == nil && $0.confidence == nil })
        #expect(TranscriptionTokenAssembly.sherpaTokens([]).isEmpty)
    }

    @Test func mismatchedParallelArraysAreDiscardedWholesale() {
        let tokens = TranscriptionTokenAssembly.sherpaTokens(utf8(["a", "b", "c"]),
                                                            timestamps: [0.1, 0.2],
                                                            durations: [0.1, 0.1, 0.1, 0.1],
                                                            logProbabilities: [0, 0])
        #expect(tokens.count == 3)
        #expect(tokens.allSatisfy { $0.start == nil && $0.duration == nil && $0.confidence == nil },
                "错位的时间/置信度比没有更糟：整列弃用")
        #expect(TranscriptionTokenAssembly.confidenceKind(of: tokens) == .unavailable)
    }

    @Test func negativeAndNonFiniteTimesBecomeNil() {
        let tokens = TranscriptionTokenAssembly.sherpaTokens(utf8(["a", "b", "c", "d"]),
                                                            timestamps: [-0.1, .nan, .infinity, 0.5],
                                                            durations: [-1, 0.2, .nan, 0],
                                                            offset: 2)
        #expect(tokens.map(\.start) == [nil, nil, nil, 2.5])
        #expect(tokens.map(\.duration) == [nil, 0.2, nil, 0])
        #expect(TranscriptionTokenAssembly.time(1, offset: .nan) == nil, "偏移本身非法时不给错原点的时间")
        #expect(TranscriptionTokenAssembly.time(1, offset: -3) == nil)
    }

    @Test func segmentOffsetIsAddedToStartsOnly() {
        // VAD 段从第 56000 个样本（3.5 s）开始：段内时间 + 段起点 = 本次请求内时间。
        let tokens = TranscriptionTokenAssembly.sherpaTokens(utf8(["血", "糖"]), timestamps: [0, 0.4],
                                                            durations: [0.3, 0.3], offset: 56_000.0 / 16_000)
        #expect(near(tokens.first?.start, 3.5))
        #expect(near(tokens.last?.start, 3.9))
        #expect(tokens.map(\.duration) == [0.3, 0.3], "偏移不改时长")
        let moved = TranscriptionTokenAssembly.shifted(tokens, by: 10)
        #expect(near(moved.first?.start, 13.5))
        #expect(TranscriptionTokenAssembly.shifted(tokens, by: .nan).allSatisfy { $0.start == nil })
    }

    // MARK: - 会话上限

    @Test func tokenLimitTruncatesTokensButNeverText() {
        let many = Array(repeating: Array("a".utf8), count: 5_000)
        #expect(TranscriptionTokenAssembly.sherpaTokens(many).count == TranscriptionTokenAssembly.sessionTokenLimit)

        var accumulator = TranscriptionEvidenceAccumulator()
        let chunk = TranscriptionSegmentEvidence(tokens: Array(repeating: TranscriptionToken(text: "a"), count: 3_000))
        accumulator.commit(text: "第一段", evidence: chunk, offset: 0)
        #expect(!accumulator.isTruncated)
        accumulator.commit(text: "第二段", evidence: chunk, offset: 60)
        #expect(accumulator.tokens.count == TranscriptionTokenAssembly.sessionTokenLimit)
        #expect(accumulator.isTruncated)
        let hypothesis = accumulator.hypothesis(engineID: "zipformer", localeIdentifier: nil, text: "第一段第二段")
        #expect(hypothesis.text == "第一段第二段", "截断只作用于词元，交付文本原样")
        #expect(hypothesis.tokens.count == TranscriptionTokenAssembly.sessionTokenLimit)
    }

    // MARK: - 语种标签与在线结果 JSON

    @Test func languageTagIsUnwrappedAndNoSpeechIsNotALanguage() {
        #expect(TranscriptionTokenAssembly.languageTag(sherpa: "<|zh|>") == "zh")
        #expect(TranscriptionTokenAssembly.languageTag(sherpa: " <|yue|> ") == "yue")
        #expect(TranscriptionTokenAssembly.languageTag(sherpa: "en") == "en")
        #expect(TranscriptionTokenAssembly.languageTag(sherpa: "<|nospeech|>") == nil)
        #expect(TranscriptionTokenAssembly.languageTag(sherpa: "") == nil)
        #expect(TranscriptionTokenAssembly.languageTag(sherpa: "<||>") == nil)
        #expect(TranscriptionTokenAssembly.languageTag(sherpa: nil) == nil)
    }

    @Test func onlineMetadataReadsPinnedJsonShape() {
        // 形状逐字取自钉版 online-recognizer.cc `AsJsonString`（timestamps 两位、ys_probs 六位小数）。
        let json = """
        { "text": "你好", "tokens": ["你", "好"], "timestamps": [0.00, 0.40], "ys_probs": [-0.105361, -0.693147], \
        "lm_probs": [], "context_scores": [], "segment": 1, "words": [], "start_time": 2.56, "is_final": false, \
        "is_eof": false}
        """
        let metadata = TranscriptionTokenAssembly.SherpaOnlineMetadata(json: json)
        #expect(metadata.startTime == 2.56)
        #expect(metadata.logProbabilities == [-0.105361, -0.693147])

        let tokens = TranscriptionTokenAssembly.sherpaTokens(utf8(["你", "好"]), timestamps: [0, 0.4],
                                                            logProbabilities: metadata.logProbabilities,
                                                            offset: metadata.startTime ?? 0)
        #expect(near(tokens.first?.start, 2.56), "端点复位后 C 结构时间从 0 计，必须加段起点")
        #expect(near(tokens.first?.confidence, 0.9, tolerance: 1e-6))
        #expect(near(tokens.last?.confidence, 0.5, tolerance: 1e-6))
    }

    @Test func malformedOnlineJsonLeavesStartTimeUnknown() {
        let broken = TranscriptionTokenAssembly.SherpaOnlineMetadata(
            json: "{ \"ys_probs\": [-inf], \"start_time\": 1.00 }")
        #expect(broken == TranscriptionTokenAssembly.SherpaOnlineMetadata(), "非法 JSON 不猜段起点")
        #expect(TranscriptionTokenAssembly.SherpaOnlineMetadata(json: nil) == TranscriptionTokenAssembly.SherpaOnlineMetadata())
        let noProbs = TranscriptionTokenAssembly.SherpaOnlineMetadata(json: "{ \"start_time\": 0.00 }")
        #expect(noProbs.startTime == 0)
        #expect(noProbs.logProbabilities == nil)
    }

    // MARK: - Apple 词段与 n-best

    @Test func appleAllZeroConfidenceMeansNotProvided() {
        let tokens = TranscriptionTokenAssembly.platformTokens([
            .init(text: "血糖", start: 0.1, duration: 0.4, confidence: 0),
            .init(text: "六点二", start: 0.6, duration: 0.5, confidence: 0),
        ])
        #expect(tokens.allSatisfy { $0.confidence == nil }, "Apple：没有识别时为 0；非 final 实测全 0")
        #expect(TranscriptionTokenAssembly.confidenceKind(of: tokens) == .unavailable)
    }

    @Test func appleMixedConfidenceKeepsGenuineZeroAndDropsNonFinite() {
        let tokens = TranscriptionTokenAssembly.platformTokens([
            .init(text: " 血糖 ", start: 0.1, duration: 0.4, confidence: 0.92),
            .init(text: "  ", start: 0.5, duration: 0.1, confidence: 0.5),
            .init(text: "六点二", start: 0.6, duration: 0.5, confidence: 0),
            .init(text: "毫摩尔", start: -1, duration: .nan, confidence: .nan),
        ], offset: 55)
        #expect(tokens.map(\.text) == ["血糖", "六点二", "毫摩尔"], "去首尾空白、丢空段")
        #expect(tokens.map(\.confidence) == [0.92, 0, nil])
        #expect(near(tokens.first?.start, 55.1), "请求内时间 + 请求在会话中的起点")
        #expect(tokens.last?.start == nil)
        #expect(tokens.last?.duration == nil)
        #expect(TranscriptionTokenAssembly.confidenceKind(of: tokens) == .engineNative)
    }

    @Test func appleTokenAlternativesExcludeSelfDuplicatesAndBlanks() {
        let tokens = TranscriptionTokenAssembly.platformTokens([
            .init(text: "Hello", confidence: 0.8, alternatives: ["Hello", "hello", " ", "Halo", "hello", "Hullo", "Hallo", "Yellow"]),
        ])
        #expect(tokens.first?.alternatives == ["hello", "Halo", "Hullo", "Hallo"], "保持引擎排序，上限 4")
    }

    @Test func nBestTextsKeepEngineOrderExcludeBestAndCap() {
        let alternatives = TranscriptionTokenAssembly.alternativeTexts(
            best: "A", candidates: ["A", " B ", "", "C", "B", "D", "E", "F"])
        #expect(alternatives == ["B", "C", "D", "E"])
        #expect(TranscriptionTokenAssembly.alternativeTexts(best: "A", candidates: ["A"]).isEmpty)
    }

    // MARK: - 汇总：置信度性质 / 加权置信度

    @Test func confidenceKindIsHonest() {
        #expect(TranscriptionTokenAssembly.confidenceKind(of: []) == .unavailable)
        #expect(TranscriptionTokenAssembly.confidenceKind(of: [TranscriptionToken(text: "a")]) == .unavailable)
        #expect(TranscriptionTokenAssembly.confidenceKind(of: [
            TranscriptionToken(text: "a"), TranscriptionToken(text: "b", confidence: 0),
        ]) == .engineNative, "引擎给出的 0 也是原生置信度")
    }

    @Test func characterWeightedConfidenceFavoursLongerTokens() {
        let tokens = [TranscriptionToken(text: "你好", confidence: 0.9), TranscriptionToken(text: "吗", confidence: 0.3),
                      TranscriptionToken(text: "呀")]
        #expect(near(TranscriptionTokenAssembly.characterWeightedConfidence(of: tokens), 0.7))
        #expect(TranscriptionTokenAssembly.characterWeightedConfidence(of: [TranscriptionToken(text: "呀")]) == nil,
                "没有任何置信度就是 nil，不得给常数")
    }

    // MARK: - 会话累加器

    @Test func singleSegmentHypothesisCarriesNativeNBest() {
        var accumulator = TranscriptionEvidenceAccumulator()
        accumulator.commit(text: "血糖六点二", evidence: TranscriptionSegmentEvidence(
            tokens: [TranscriptionToken(text: "血糖", start: 0.2, confidence: 0.9)],
            alternativeTexts: ["血糖六点而"]), offset: 0)
        let hypothesis = accumulator.hypothesis(engineID: "classic", localeIdentifier: "zh-CN", text: "血糖六点二")
        #expect(hypothesis.engineID == "classic")
        #expect(hypothesis.localeIdentifier == "zh-CN")
        #expect(hypothesis.alternativeTexts == ["血糖六点而"])
        #expect(hypothesis.confidenceKind == .engineNative)
    }

    @Test func multiSegmentAlternativesSwapOneSegmentAtATimeRankFirst() {
        var accumulator = TranscriptionEvidenceAccumulator()
        accumulator.commit(text: "早上", evidence: TranscriptionSegmentEvidence(
            tokens: [TranscriptionToken(text: "早上", start: 0.1)], alternativeTexts: ["早尚"]), offset: 0)
        // 只保留了部分结果的段：没有证据，但必须占位，否则 n-best 拼不回交付文本。
        accumulator.commit(text: "血压", evidence: nil, offset: 55)
        accumulator.commit(text: "一百二", evidence: TranscriptionSegmentEvidence(
            tokens: [TranscriptionToken(text: "一百二", start: 0.2)], alternativeTexts: ["一百而", "一白二"]), offset: 110)
        let delivered = TranscriptJoiner.join(["早上", "血压", "一百二"])
        let hypothesis = accumulator.hypothesis(engineID: "classic", localeIdentifier: nil, text: delivered)
        #expect(hypothesis.text == delivered)
        #expect(hypothesis.alternativeTexts == ["早尚血压一百二", "早上血压一百而", "早上血压一白二"],
                "每条只换一段：先各段第 1 替代，再第 2 替代；不做跨段组合")
        #expect(near(hypothesis.tokens.map(\.start), [0.1, 110.2]), "各段词元按该段在会话中的起点平移")
    }

    @Test func emptyCommitsAddNoSegmentAndEmptyEvidenceIsHonest() {
        var accumulator = TranscriptionEvidenceAccumulator()
        accumulator.commit(text: "  ", evidence: TranscriptionSegmentEvidence(alternativeTexts: ["x"]), offset: 0)
        #expect(accumulator.isEmpty)
        let hypothesis = accumulator.hypothesis(engineID: "qwen3", localeIdentifier: nil, text: "")
        #expect(hypothesis.tokens.isEmpty)
        #expect(hypothesis.confidenceKind == .unavailable)
        #expect(hypothesis.alternativeTexts.isEmpty)
        #expect(hypothesis.languageTag == nil)
    }

    @Test func dominantLanguageIsWeightedByCommittedCharacters() {
        var accumulator = TranscriptionEvidenceAccumulator()
        accumulator.commit(text: "你好", evidence: TranscriptionSegmentEvidence(languageTag: "zh"), offset: 0)
        accumulator.commit(text: "blood pressure", evidence: TranscriptionSegmentEvidence(languageTag: "en"), offset: 1)
        accumulator.commit(text: "再见", evidence: TranscriptionSegmentEvidence(languageTag: "zh"), offset: 2)
        #expect(accumulator.languageTag == "en", "按字数加权：14 > 4")

        var tie = TranscriptionEvidenceAccumulator()
        tie.commit(text: "ab", evidence: TranscriptionSegmentEvidence(languageTag: "en"), offset: 0)
        tie.commit(text: "你好", evidence: TranscriptionSegmentEvidence(languageTag: "zh"), offset: 0)
        #expect(tie.languageTag == "en", "平局取先出现者")
    }

    @Test func segmentEvidenceCollapsesVadSegmentsOntoRequestTimeline() {
        // sherpa 运行时：一个识别请求内两段 VAD，各自段内时间 + 段起点，再整体交给会话协调器。
        var job = TranscriptionEvidenceAccumulator()
        job.commit(text: "血糖", evidence: TranscriptionSegmentEvidence(
            tokens: TranscriptionTokenAssembly.sherpaTokens(utf8(["血", "糖"]), timestamps: [0, 0.3]),
            languageTag: "zh"), offset: 1.0)
        job.commit(text: "六点二", evidence: TranscriptionSegmentEvidence(
            tokens: TranscriptionTokenAssembly.sherpaTokens(utf8(["六", "点", "二"]), timestamps: [0, 0.2, 0.4]),
            languageTag: "zh"), offset: 4.0)
        let collapsed = job.segmentEvidence
        #expect(collapsed.tokens.map(\.text) == ["血", "糖", "六", "点", "二"])
        #expect(near(collapsed.tokens.map(\.start), [1.0, 1.3, 4.0, 4.2, 4.4]))
        #expect(collapsed.languageTag == "zh")
        #expect(collapsed.alternativeTexts.isEmpty, "sherpa 只有 1-best，不得捏造 n-best")

        var session = TranscriptionEvidenceAccumulator()
        session.commit(text: TranscriptJoiner.join(["血糖", "六点二"]), evidence: collapsed, offset: 25)
        #expect(session.tokens.first?.start == 26.0, "请求在会话中的起点再叠加一次")
    }

    // MARK: - FR17.7 形状护栏

    @Test func evidenceTypesCarryNoAudio() {
        let evidence = Mirror(reflecting: TranscriptionSegmentEvidence())
        #expect(evidence.children.compactMap { $0.label } == ["tokens", "alternativeTexts", "languageTag"],
                "证据只含文本/时间/置信度，不得夹带音频或文件引用")
        for child in evidence.children {
            let type = String(describing: type(of: child.value))
            #expect(!type.contains("URL") && !type.contains("Data") && !type.contains("Float"), "出现 \(type) = 音频通道")
        }
        let segment = Mirror(reflecting: TranscriptionTokenAssembly.PlatformSegment(text: "a"))
        #expect(segment.children.compactMap { $0.label } == ["text", "start", "duration", "confidence", "alternatives"])
    }
}
