import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

// binds: SU-M15-ASRCONSENSUS — 保守生产选择器：两副源同键才替换；数字/单位/否定/极性保护；只替换不生成
@Suite("SU-M15-ASRCONSENSUS · 生产文本一致性选择器")
struct TranscriptionConsensusSelectorTests {
    private static let policy = HypothesisFusionMedicalPolicy.standard

    private static func hypothesis(_ engine: String, _ text: String) -> TranscriptionHypothesis {
        TranscriptionHypothesis(engineID: engine, localeIdentifier: "zh-Hans-CN", text: text)
    }

    @Test func twoSecondariesAgreeingReplacePrimaryToken() {
        let primary = Self.hypothesis("qwen3", "今天头通")
        let zh = Self.hypothesis("apple-zh-CN", "今天头痛")
        let en = Self.hypothesis("apple-en-US", "今天头痛")
        let result = TranscriptionConsensusSelector.select(primary: primary, secondaries: [zh, en],
                                                           policy: Self.policy)
        #expect(result.text == "今天头痛")
        #expect(result.edits.count == 1)
        #expect(result.edits[0].original == "通")
        #expect(result.edits[0].replacement == "痛")
        #expect(result.edits[0].supporters == ["apple-zh-CN", "apple-en-US"])
    }

    @Test func singleSecondaryNeverRewrites() {
        let primary = Self.hypothesis("qwen3", "今天头通")
        let zh = Self.hypothesis("apple-zh-CN", "今天头痛")
        let result = TranscriptionConsensusSelector.select(primary: primary, secondaries: [zh],
                                                           policy: Self.policy)
        #expect(result.text == "今天头通")
        #expect(result.edits.isEmpty)
    }

    @Test func protectedNumberAndUnitNeverRewrite() {
        let primary = Self.hypothesis("qwen3", "血压120mmHg")
        let a = Self.hypothesis("apple-zh-CN", "血压130mmHg")
        let b = Self.hypothesis("apple-en-US", "血压130mmHg")
        let result = TranscriptionConsensusSelector.select(primary: primary, secondaries: [a, b],
                                                           policy: Self.policy)
        #expect(result.text == "血压120mmHg")
        #expect(result.edits.isEmpty)
        #expect(result.protectedColumns > 0)
    }

    @Test func negationNeverRewrites() {
        let primary = Self.hypothesis("qwen3", "我不发热")
        let a = Self.hypothesis("apple-zh-CN", "我没发热")
        let b = Self.hypothesis("apple-en-US", "我没发热")
        let result = TranscriptionConsensusSelector.select(primary: primary, secondaries: [a, b],
                                                           policy: Self.policy)
        #expect(result.text == "我不发热")
        #expect(result.edits.isEmpty)
        #expect(result.protectedColumns > 0)
    }

    @Test func punctuationAndNonEditedTextStayVerbatim() {
        let primary = Self.hypothesis("qwen3", "头痛，血压正常。")
        let a = Self.hypothesis("apple-zh-CN", "头痛，血压正常。")
        let b = Self.hypothesis("apple-en-US", "头痛，血压正常。")
        let result = TranscriptionConsensusSelector.select(primary: primary, secondaries: [a, b],
                                                           policy: Self.policy)
        #expect(result.text == primary.text)
        #expect(result.edits.isEmpty)
    }

    @Test func resultWrapperPreservesHypothesesAndSelectedText() {
        let primary = Self.hypothesis("qwen3", "今天头通")
        let result = TranscriptionResult(
            text: "今天头通", confidence: 0.9, resolvedLocale: "zh-Hans-CN", segmented: false,
            completion: .final, engineID: "qwen3",
            hypotheses: [primary, Self.hypothesis("apple-zh-CN", "今天头痛"),
                         Self.hypothesis("apple-en-US", "今天头痛")])
        let selected = TranscriptionConsensusSelector.select(result, policy: Self.policy)
        #expect(selected.text == "今天头痛")
        #expect(selected.hypotheses.count == 3)
        #expect(selected.completion == .final)
    }
}
