import Foundation
import Testing
@testable import Domain

// binds: SU-M15-ASRFUSION — 分词、严格等价键（数值等价/拼音不等价）、UTF-16 区间、词类、置信度映射、对齐
@Suite("SU-M15-ASRFUSION · 融合分词与等价键（汉字逐字/拉丁成词/数字整体/拼音只作软代价）")
struct HypothesisFusionTokenizerTests {
    static func keys(_ text: String) -> [String] {
        HypothesisFusionTokenizer.tokenize(text).map { $0.key }
    }

    static func classes(_ text: String) -> [HypothesisFusionTokenClass] {
        HypothesisFusionTokenizer.tokenize(text).map { $0.tokenClass }
    }

    @Test("汉字逐字、拉丁成词、数字整体；标点/空白不成词元；区间为 UTF-16")
    func tokenizesByScriptWithUTF16Ranges() {
        let tokens = HypothesisFusionTokenizer.tokenize("今天血压120 80，Yes！")
        let surfaces = tokens.map { $0.surface }
        let ranges = tokens.map { $0.utf16Range }
        let scripts = tokens.map { $0.script }
        #expect(surfaces == ["今", "天", "血", "压", "120", "80", "Yes"])
        #expect(ranges == [0..<1, 1..<2, 2..<3, 3..<4, 4..<7, 8..<10, 11..<14])
        #expect(scripts == [.han, .han, .han, .han, .digit, .digit, .latin])
        let emoji = HypothesisFusionTokenizer.tokenize("a😀b")
        let emojiRanges = emoji.map { $0.utf16Range }
        #expect(emojiRanges == [0..<1, 3..<4])
    }

    @Test("数值等价键：五百 ≡ 500 ≡ ５００；零点五 ≡ 0.50；单字 十/五 是数字")
    func numbersCompareByValue() {
        #expect(Self.keys("五百") == ["#500"])
        #expect(Self.keys("500") == ["#500"])
        #expect(Self.keys("５００") == ["#500"])
        #expect(Self.keys("零点五") == Self.keys("0.50"))
        #expect(Self.keys("两百") == ["#200"])
        #expect(Self.keys("十") == ["#10"])
        #expect(Self.keys("五") == ["#5"])
        #expect(Self.keys("负五") == ["#-5"])
        #expect(Self.classes("十岁") == [.number, .word])
        #expect(Self.keys("3.5.") == ["#3.5"])
    }

    @Test("ICU 前缀解析被回写校验拦下：十五六/一二零/一百二 不得给出错误数值", arguments: [
        ("十五六", ["#10", "#5", "#6"]),
        ("一二零", ["#1", "#2", "#0"]),
        ("一百二", ["#1", "百", "#2"]),
        ("十一点", ["#11", "点"]),
        ("第一", ["第", "#1"]),
        ("万一", ["万", "#1"]),
    ])
    func lenientParsesAreRejected(_ pair: (String, [String])) {
        #expect(Self.keys(pair.0) == pair.1)
    }

    @Test("中文数字求值公开入口：两/零/小数可解，前缀解析与非数字为 nil")
    func chineseNumeralValueValidatesRoundTrip() {
        #expect(HypothesisFusionTokenizer.chineseNumeralValue("一千零五十") == 1_050)
        #expect(HypothesisFusionTokenizer.chineseNumeralValue("两百") == 200)
        #expect(HypothesisFusionTokenizer.chineseNumeralValue("三十七点五") == 37.5)
        #expect(HypothesisFusionTokenizer.chineseNumeralValue("是") == nil)
        #expect(HypothesisFusionTokenizer.chineseNumeralValue("十五六") == nil)
    }

    @Test("拼音只作对齐软代价，绝不作等价键：是/十、历/厉 是不同候选")
    func pinyinIsNeverAnEquivalenceKey() {
        let shi = HypothesisFusionTokenizer.tokenize("是")[0]
        let ten = HypothesisFusionTokenizer.tokenize("十")[0]
        #expect(shi.key != ten.key)
        #expect(shi.phonetic == ten.phonetic)
        #expect(HypothesisFusionAligner.cost(shi, ten) == HypothesisFusionAligner.homophoneCost)
        let yes = HypothesisFusionTokenizer.tokenize("Yes")[0]
        let ye = HypothesisFusionTokenizer.tokenize("耶")[0]
        #expect(HypothesisFusionAligner.cost(yes, ye) == HypothesisFusionAligner.crossScriptPrefixCost)
        let li = HypothesisFusionTokenizer.tokenize("历")[0]
        let fierce = HypothesisFusionTokenizer.tokenize("厉")[0]
        #expect(li.key != fierce.key)
        #expect(HypothesisFusionAligner.cost(li, li) == HypothesisFusionAligner.matchCost)
    }

    @Test("严格键：NFKC + 拉丁小写；全角拉丁、µ 统一")
    func strictKeysNormalizeWidthAndCase() {
        #expect(Self.keys("ＯＫ ok Ok") == ["ok", "ok", "ok"])
        #expect(Self.keys("5µg") == ["#5", "μg"])
        #expect(Self.keys("don’t") == ["don't"])
    }

    @Test("词类：单位（含组合与符号）、否定词（含缩约）、极性词；「上/下」不保护")
    func tokenClassesFollowVocabulary() {
        #expect(Self.classes("五百毫克") == [.number, .unit, .unit])
        #expect(Self.classes("500 mg/dL 37℃ 50%") == [.number, .unit, .unit, .number, .unit, .number, .unit])
        #expect(Self.classes("我不发热") == [.word, .negation, .word, .word])
        #expect(Self.classes("I don't cough") == [.word, .negation, .word])
        #expect(Self.classes("左侧阳性") == [.polarity, .word, .polarity, .polarity])
        #expect(Self.classes("饭前空腹") == [.polarity, .polarity, .polarity, .polarity])
        #expect(Self.classes("上下") == [.word, .word])
        #expect(Self.classes("negative left") == [.polarity, .polarity])
    }

    @Test("受保护词条按同一分词的键序列整段匹配（大小写不敏感）")
    func protectedTermsMatchWholeKeySequences() {
        let tokens = HypothesisFusionTokenizer.tokenize("吃阿莫西林和IBUPROFEN，阿莫", protectedTerms: ["阿莫西林", "ibuprofen"])
        let flags = tokens.map { $0.isProtectedTerm }
        #expect(flags == [false, true, true, true, true, false, true, false, false])
    }

    @Test("置信度映射：按顺序定位引擎 token，被连续完整覆盖才取最小值；否则不分档")
    func confidencesMapOntoFusionTokens() {
        let hypothesis = TranscriptionHypothesis(
            engineID: "e", text: "今天血压120",
            tokens: [TranscriptionToken(text: "今天", confidence: 0.9), TranscriptionToken(text: "血压", confidence: 0.4),
                     TranscriptionToken(text: "12", confidence: 0.8), TranscriptionToken(text: "0")],
            confidenceKind: .engineNative)
        let lexicon = HypothesisFusionLexicon()
        let mapped = lexicon.tokens(for: hypothesis, protectedTerms: []).map { $0.confidence }
        #expect(mapped == [0.9, 0.9, 0.4, 0.4, nil])
        let missing = TranscriptionHypothesis(engineID: "e", text: "今天", tokens: [TranscriptionToken(text: "明天", confidence: 0.9)],
                                              confidenceKind: .engineNative)
        #expect(lexicon.tokens(for: missing, protectedTerms: []).map { $0.confidence } == [nil, nil])
        let unavailable = TranscriptionHypothesis(engineID: "e", text: "今天", tokens: [TranscriptionToken(text: "今天", confidence: 0.9)])
        #expect(lexicon.tokens(for: unavailable, protectedTerms: []).map { $0.confidence } == [nil, nil])
        #expect(HypothesisFusionCalibration.confidenceBin(for: 1.0, binCount: 10) == 9)
        #expect(HypothesisFusionCalibration.confidenceBin(for: 0.0, binCount: 10) == 0)
        #expect(HypothesisFusionCalibration.confidenceBin(for: .nan, binCount: 10) == nil)
    }

    @Test("对齐：单引擎插入另成插入列，后续副轨匹配同一插入列")
    func alignmentBuildsInsertionColumns() {
        let lexicon = HypothesisFusionLexicon()
        let primary = lexicon.tokenize("今天血压", protectedTerms: [])
        var columns = HypothesisFusionAligner.skeleton(primary)
        columns = HypothesisFusionAligner.merge(columns, engineIndex: 1, tokens: lexicon.tokenize("今天嗯血压", protectedTerms: []))
        columns = HypothesisFusionAligner.merge(columns, engineIndex: 2, tokens: lexicon.tokenize("今天嗯血压", protectedTerms: []))
        let anchors = columns.map { $0.anchor.surface }
        let insertionFlags = columns.map { $0.isInsertion }
        #expect(anchors == ["今", "天", "嗯", "血", "压"])
        #expect(insertionFlags == [false, false, true, false, false])
        let votes = columns[2].votes.map { $0.token?.surface }
        #expect(votes == [nil, "嗯", "嗯"])
        #expect(columns.allSatisfy { $0.votes.count == 3 })
    }

    @Test("校准表 JSON 契约：snake_case 键往返一致，结构自检拦非法计数")
    func calibrationDecodesSnakeCaseJSON() throws {
        let json = """
        {"version":"2026.11.0","corpus_size":600,"code_switched_count":120,"release_passed":true,
         "confidence_bin_count":10,"cells":[
          {"engine_id":"qwen3","script":"han","token_class":"word","correct":9400,"total":10000},
          {"engine_id":"qwen3","script":"latin","token_class":"polarity","confidence_bin":9,"correct":95,"total":100}]}
        """
        let decoded = try JSONDecoder().decode(HypothesisFusionCalibration.self, from: Data(json.utf8))
        #expect(decoded.releasePassed)
        #expect(decoded.cells.count == 2)
        #expect(decoded.cells[1].confidenceBin == 9)
        #expect(decoded.cells[1].tokenClass == .polarity)
        #expect(decoded.isWellFormed)
        let encoded = try JSONEncoder().encode(decoded)
        let roundTrip = try JSONDecoder().decode(HypothesisFusionCalibration.self, from: encoded)
        #expect(roundTrip == decoded)
        var badBin = decoded
        badBin.cells[1].confidenceBin = 10
        #expect(!badBin.isWellFormed)
        var badCount = decoded
        badCount.codeSwitchedCount = 601
        #expect(!badCount.isWellFormed)
    }
}
