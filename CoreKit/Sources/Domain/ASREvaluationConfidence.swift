import Foundation

/// 置信度区分度（辩论终裁判据 1）：引擎逐词置信度能否把「对的词」排在「错的词」前面。
///
/// 口径：用 MER 参考对齐给假设的每个 token 判对错——`.match` = 对，替换/插入 = 错（删除没有假设 token，不入样本）；
/// 对每个带置信度的假设 token 取一个样本（置信度、对/错），计算「置信度预测正确」的 **AUROC**
/// （Mann–Whitney U 的秩和等价式；同分取平均秩 ⇔ 平局计 0.5）。无置信度样本或只有一类 → nil。
///
/// 引擎 token 与 MER token 不必一一对应（Apple 段可含多字、sherpa 词片可拆词）：按归一后字符区间重叠映射——
/// 引擎 token 文本须按顺序出现在 1-best 原文中（Apple `segment.substring` / sherpa token 皆然；比较不分大小写），找不到的跳过；
/// 一个 MER token 覆盖多个引擎 token 时取**最小**置信度（词片拼成的词只与最弱的一片一样可信）。
/// 置信度为引擎原生、未校准值，跨引擎不可比——AUROC 只看排序，正适合逐引擎各自评估。
extension ASREvaluation {

    /// 一个假设 token 的（置信度，对/错）样本；逐句留存，可直接作离线校准表的输入。
    public struct ConfidenceSample: Sendable, Equatable, Codable {
        public var confidence: Double
        public var isCorrect: Bool

        public init(confidence: Double, isCorrect: Bool) {
            self.confidence = confidence
            self.isCorrect = isCorrect
        }
    }

    /// 某系统的置信度区分度汇总。
    public struct ConfidenceDiscrimination: Sendable, Equatable, Codable {
        public var sampleCount: Int
        public var correctCount: Int
        public var incorrectCount: Int
        /// 无样本或单类 → nil。
        public var auroc: Double?

        public static let empty = ConfidenceDiscrimination(sampleCount: 0, correctCount: 0, incorrectCount: 0, auroc: nil)

        public init(sampleCount: Int, correctCount: Int, incorrectCount: Int, auroc: Double?) {
            self.sampleCount = sampleCount
            self.correctCount = correctCount
            self.incorrectCount = incorrectCount
            self.auroc = auroc
        }

        public init(samples: [ConfidenceSample]) {
            let correct = samples.filter { $0.isCorrect }.count
            self.init(sampleCount: samples.count, correctCount: correct, incorrectCount: samples.count - correct,
                      auroc: ASREvaluation.confidenceAUROC(samples))
        }
    }

    /// AUROC = P(对词置信度 > 错词置信度) + ½·P(相等)。秩和法：U = R₊ − n₊(n₊+1)/2，AUROC = U / (n₊·n₋)。
    /// 无样本或只有一类 → nil。
    public static func confidenceAUROC(_ samples: [ConfidenceSample]) -> Double? {
        let positives = samples.filter { $0.isCorrect }.count
        let negatives = samples.count - positives
        guard positives > 0, negatives > 0 else { return nil }
        let sorted = samples.sorted { $0.confidence < $1.confidence }
        var positiveRankSum = 0.0
        var start = 0
        while start < sorted.count {
            var end = start
            while end + 1 < sorted.count && sorted[end + 1].confidence == sorted[start].confidence { end += 1 }
            // 同分组占秩 start+1 … end+1，取平均秩
            let averageRank = Double(start + end + 2) / 2
            let positivesInGroup = sorted[start...end].filter { $0.isCorrect }.count
            positiveRankSum += averageRank * Double(positivesInGroup)
            start = end + 1
        }
        let u = positiveRankSum - Double(positives) * Double(positives + 1) / 2
        return u / (Double(positives) * Double(negatives))
    }

    /// 把引擎逐词置信度映射到 `hypothesis` 的 MER token 上（与 `MixedErrorRate.tokenize(hypothesis)` 同序同长）；
    /// 未被任何带置信度的引擎 token 覆盖的位置为 nil。
    public static func tokenConfidences(hypothesis: String, tokens: [TranscriptionToken]) -> [Double?] {
        let ranged = MixedErrorRate.tokenizeWithRanges(hypothesis)
        let haystack = ranged.scalars.map { foldCase($0) }
        var covered: [(range: Range<Int>, confidence: Double)] = []
        var cursor = 0
        for token in tokens {
            let trimmed = MixedErrorRate.normalize(token.text).trimmingCharacters(in: .whitespacesAndNewlines)
            let needle = trimmed.unicodeScalars.map { foldCase($0) }
            guard !needle.isEmpty, let start = firstOccurrence(of: needle, in: haystack, from: cursor) else {
                continue
            }
            cursor = start + needle.count
            if let confidence = token.confidence { covered.append((start ..< cursor, confidence)) }
        }
        return ranged.ranges.map { range in
            covered.filter { $0.range.overlaps(range) }.map { $0.confidence }.min()
        }
    }

    /// 由已对齐的假设与逐词置信度生成样本（对 = `.match`；错 = 替换/插入）。
    static func confidenceSamples(alignment: MixedErrorRate.Result, confidences: [Double?]) -> [ConfidenceSample] {
        var samples: [ConfidenceSample] = []
        for pair in alignment.alignment {
            guard let index = pair.hypothesisIndex, index < confidences.count,
                  let confidence = confidences[index] else { continue }
            samples.append(ConfidenceSample(confidence: confidence, isCorrect: pair.operation == .match))
        }
        return samples
    }

    /// 逐标量小写（只取单标量映射，保持下标一一对应；多标量映射的少数字母保持原样）。
    private static func foldCase(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let lower = scalar.properties.lowercaseMapping.unicodeScalars
        if lower.count == 1, let first = lower.first { return first }
        return scalar
    }

    private static func firstOccurrence(of needle: [Unicode.Scalar], in haystack: [Unicode.Scalar],
                                        from start: Int) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var index = start
        while index + needle.count <= haystack.count {
            var hit = true
            for offset in 0..<needle.count where haystack[index + offset] != needle[offset] {
                hit = false
                break
            }
            if hit { return index }
            index += 1
        }
        return nil
    }
}
