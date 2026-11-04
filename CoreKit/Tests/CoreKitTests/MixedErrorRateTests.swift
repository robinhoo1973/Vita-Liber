import Foundation
import Testing
@testable import Domain

// binds: SU-M15-ASREVAL — MER 计量口径（汉字按字 / 英文按词小写 / 数字整体 / NFKC 去标点）与确定性对齐路径
@Suite("SU-M15-ASREVAL · MER 混合错误率（汉字按字/英文按词/数字整体）")
struct MixedErrorRateTests {

    private func texts(_ tokens: [MixedErrorRate.Token]) -> [String] { tokens.map { $0.text } }

    // MARK: 分词

    @Test func mixedSentenceSplitsHanByCharacterAndLatinByWord() {
        let tokens = MixedErrorRate.tokenize("Yes，你说的很对")
        #expect(texts(tokens) == ["yes", "你", "说", "的", "很", "对"])
        #expect(tokens.first?.kind == .word)
        #expect(tokens.dropFirst().allSatisfy { $0.kind == .cjk })
    }

    @Test func fullWidthFormsNormalizeThroughNFKC() {
        let tokens = MixedErrorRate.tokenize("５００ｍｇ，ＯＫ")
        #expect(texts(tokens) == ["500", "mg", "ok"])
        #expect(tokens.map { $0.kind } == [.number, .word, .word])
    }

    @Test func numbersStayWholeWithDecimalAndThousandsGrouping() {
        let tokens = MixedErrorRate.tokenize("体温37.5度，1,000 IU，血压120，80，12,345,678")
        #expect(texts(tokens) == ["体", "温", "37.5", "度", "1000", "iu", "血", "压", "120", "80", "12345678"])
        // 句末小数点、多余小数点不并入数字
        #expect(texts(MixedErrorRate.tokenize("120. 3.14.15")) == ["120", "3.14", "15"])
    }

    @Test func apostrophesInsideWordsAreKeptAndCurlyFormsFolded() {
        #expect(texts(MixedErrorRate.tokenize("I don’t know, it's 'fine'")) == ["i", "don't", "know", "it's", "fine"])
    }

    @Test func punctuationAndSymbolsOnlySeparate() {
        #expect(texts(MixedErrorRate.tokenize("你好，世界！……（测试）")) == ["你", "好", "世", "界", "测", "试"])
        #expect(MixedErrorRate.tokenize("。，！？").isEmpty)
        #expect(MixedErrorRate.evaluate(reference: "你好，世界！", hypothesis: "你好世界").errorCount == 0)
    }

    @Test func chineseNumeralsAreCountedByCharacterNotAsDigits() {
        // 评测口径是字面原样：「五百」≠「500」（ITN 差异如实计错）
        let result = MixedErrorRate.evaluate(reference: "五百毫克", hypothesis: "500毫克")
        #expect(result.referenceLength == 4)
        #expect(result.substitutions == 1)
        #expect(result.deletions == 1)
        #expect(result.insertions == 0)
    }

    // MARK: 计量

    @Test func caseDifferencesAreNotErrors() {
        #expect(MixedErrorRate.evaluate(reference: "Vitamin D 和 CT", hypothesis: "vitamin d和ct").errorCount == 0)
    }

    @Test func emptyStringsFollowCharacterErrorRateConvention() {
        let bothEmpty = MixedErrorRate.evaluate(reference: "", hypothesis: "")
        #expect(bothEmpty.rate == 0)
        #expect(bothEmpty.alignment.isEmpty)
        let onlyHypothesis = MixedErrorRate.evaluate(reference: "", hypothesis: "abc 你")
        #expect(onlyHypothesis.insertions == 2)
        #expect(onlyHypothesis.rate == 1)
        let onlyReference = MixedErrorRate.evaluate(reference: "你好", hypothesis: "")
        #expect(onlyReference.deletions == 2)
        #expect(onlyReference.rate == 1)
    }

    @Test func completelyWrongHypothesisScoresOne() {
        let result = MixedErrorRate.evaluate(reference: "今天头疼", hypothesis: "明年脚痛")
        #expect(result.substitutions == 4)
        #expect(result.matches == 0)
        #expect(result.rate == 1)
        // 插入不设上限：MER 可以大于 1
        #expect(MixedErrorRate.evaluate(reference: "好", hypothesis: "好好好").rate == 2)
    }

    @Test func mixedScriptCountsSubstitutionsAndInsertions() {
        // 参考 6 token；假设把英文药名音译成 4 个汉字：1 替换 + 3 插入
        let result = MixedErrorRate.evaluate(reference: "我吃了 aspirin 100 mg", hypothesis: "我吃了阿司匹林100mg")
        #expect(result.referenceLength == 6)
        #expect(result.substitutions == 1)
        #expect(result.insertions == 3)
        #expect(result.deletions == 0)
        #expect(result.matches == 5)
        #expect(abs(result.rate - 4.0 / 6.0) < 1e-12)
    }

    // MARK: 对齐路径

    @Test func alignmentPrefersMoreMatchesThenDiagonalDeletionInsertion() {
        // 「a b」→「b a」：两替换与「插入+匹配+删除」同为代价 2，取匹配更多者；路径固定
        let result = MixedErrorRate.evaluate(reference: "a b", hypothesis: "b a")
        #expect(result.alignment == [
            MixedErrorRate.AlignedPair(operation: .insertion, referenceIndex: nil, hypothesisIndex: 0),
            MixedErrorRate.AlignedPair(operation: .match, referenceIndex: 0, hypothesisIndex: 1),
            MixedErrorRate.AlignedPair(operation: .deletion, referenceIndex: 1, hypothesisIndex: nil),
        ])
        #expect(result.errorCount == 2)
        #expect(MixedErrorRate.evaluate(reference: "a b", hypothesis: "b a") == result)
    }

    @Test func alignmentCoversEveryTokenExactlyOnce() {
        let result = MixedErrorRate.evaluate(reference: "我不发热 37.5 度", hypothesis: "我发烧37.5度了")
        let referenceIndices = result.alignment.compactMap { $0.referenceIndex }
        let hypothesisIndices = result.alignment.compactMap { $0.hypothesisIndex }
        #expect(referenceIndices == Array(0..<result.referenceTokens.count))
        #expect(hypothesisIndices == Array(0..<result.hypothesisTokens.count))
        #expect(result.matches + result.substitutions + result.deletions == result.referenceLength)
        #expect(result.matches + result.substitutions + result.insertions == result.hypothesisTokens.count)
    }

    @Test func preservationRequiresAllMatchesAndNoInnerInsertion() {
        let result = MixedErrorRate.evaluate(reference: "阿莫西林", hypothesis: "阿莫X西林")
        #expect(!result.preserves(referenceRange: 0..<4))
        #expect(result.preserves(referenceRange: 0..<2))
        #expect(result.preserves(referenceRange: 2..<4))
        #expect(result.hypothesisText(alignedTo: 0..<4) == "阿莫x西林")
        #expect(!result.preserves(referenceRange: 3..<5))
        #expect(!result.preserves(referenceRange: 2..<2))
        let deleted = MixedErrorRate.evaluate(reference: "我不发热", hypothesis: "我发热")
        #expect(!deleted.preserves(referenceRange: 1..<2))
        #expect(deleted.hypothesisText(alignedTo: 1..<2) == "")
    }

    @Test func joinedSpacesOnlyBetweenNonHanTokens() {
        #expect(MixedErrorRate.joined(MixedErrorRate.tokenize("阿莫西林 500mg Vitamin D")) == "阿莫西林500 mg vitamin d")
    }
}
