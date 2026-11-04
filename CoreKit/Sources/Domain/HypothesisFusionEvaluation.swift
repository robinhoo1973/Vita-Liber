import Foundation

/// 融合相对主轨的修复/伤害计数（离线评测工具链用于计算 harm ratio）。
///
/// Domain 在运行时不知道真值，本类型只在**有参考文本**（金样）时由评测工具调用；不参与融合决策。
public struct HypothesisFusionEvaluation: Sendable, Equatable {
    /// 主轨错、融合对的位置数。
    public var fixes: Int
    /// 主轨对、融合错的位置数。
    public var harms: Int

    public init(fixes: Int, harms: Int) {
        self.fixes = fixes
        self.harms = harms
    }
}

extension HypothesisFusion {
    /// 以参考文本为骨架，把主轨与融合输出依次并入同一混淆网络（与融合**同一**分词、严格等价键与
    /// DP 对齐），逐列比较：主轨错且融合对 = fix；主轨对且融合错 = harm。
    /// 参考列的「对」= 票的严格键等于参考词元键（数值等价：「五百」≡「500」）；插入列（参考在此为 ∅）
    /// 的「对」= 投 ∅。两者同错（含错成不同写法）不计。
    public static func evaluate(fused: String, reference: String, primary: String) -> HypothesisFusionEvaluation {
        let lexicon = HypothesisFusionLexicon()
        lexicon.prefetchPinyin([reference, primary, fused])
        var columns = HypothesisFusionAligner.skeleton(lexicon.tokenize(reference, protectedTerms: []))
        columns = HypothesisFusionAligner.merge(columns, engineIndex: 1,
                                                tokens: lexicon.tokenize(primary, protectedTerms: []))
        columns = HypothesisFusionAligner.merge(columns, engineIndex: 2,
                                                tokens: lexicon.tokenize(fused, protectedTerms: []))
        var fixes = 0
        var harms = 0
        for column in columns where column.votes.count == 3 {
            let truth = column.isInsertion ? nil : column.anchor.key
            let primaryRight = column.votes[1].token?.key == truth
            let fusedRight = column.votes[2].token?.key == truth
            if !primaryRight, fusedRight { fixes += 1 }
            if primaryRight, !fusedRight { harms += 1 }
        }
        return HypothesisFusionEvaluation(fixes: fixes, harms: harms)
    }

    /// 便捷重载：直接比较一次融合结果与其主轨假设。
    public static func evaluate(fused: FusedTranscript, reference: String,
                                primary: TranscriptionHypothesis) -> HypothesisFusionEvaluation {
        evaluate(fused: fused.text, reference: reference, primary: primary.text)
    }
}
