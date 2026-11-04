import Foundation

/// harm/fix（辩论终裁判据 2；round3 P2「harm ratio = 新增错误 / 修正数，相对主轨」）：参考锚定，逐参考 token
/// 比较主轨与候选（如融合输出）——两者各自按 MER 与参考对齐：
/// - 主轨错（替换/删除）且候选对（匹配）= **fix**；主轨对且候选错 = **harm**；两者都错不计（换错不算修也不算伤）。
/// - 插入不锚定参考 token，按**参考间隙**计（间隙 k 位于参考 token k−1 与 k 之间）：候选在某间隙多出的插入
///   计 harm（新增插入），少出的计 fix（去掉主轨的多余词）。同一处多出的词若被两次对齐放进相邻间隙，
///   会各计一次 harm 与 fix——对称、把比值推向 1，偏保守（更易拦下自动改写），不偏袒候选。
extension ASREvaluation {

    public struct HarmFix: Sendable, Equatable, Codable {
        public var primaryEngineID: String
        public var candidateEngineID: String
        /// 两者都已计分的句数（failed 按空假设；skipped 不计）。
        public var utteranceCount: Int
        public var tokenFixes: Int
        public var tokenHarms: Int
        public var insertionFixes: Int
        public var insertionHarms: Int
        public var fixes: Int
        public var harms: Int
        /// harms / fixes；fixes = 0 → nil（此时 harms > 0 即视为无穷大，见 `exceeds(_:)`）。
        public var harmFixRatio: Double?

        public init(primaryEngineID: String, candidateEngineID: String, utteranceCount: Int,
                    tokenFixes: Int, tokenHarms: Int, insertionFixes: Int, insertionHarms: Int) {
            self.primaryEngineID = primaryEngineID
            self.candidateEngineID = candidateEngineID
            self.utteranceCount = utteranceCount
            self.tokenFixes = tokenFixes
            self.tokenHarms = tokenHarms
            self.insertionFixes = insertionFixes
            self.insertionHarms = insertionHarms
            fixes = tokenFixes + insertionFixes
            harms = tokenHarms + insertionHarms
            harmFixRatio = fixes > 0 ? Double(harms) / Double(fixes) : nil
        }

        /// harm/fix 是否超过上限（乘法形式免除零：fixes = 0 且 harms > 0 视为超过；0/0 不超过）。
        public func exceeds(_ maximumRatio: Double) -> Bool {
            Double(harms) > maximumRatio * Double(fixes)
        }
    }

    /// 单句 harm/fix（参考、主轨、候选均为原文）。
    public static func harmFix(reference: String, primary: String, candidate: String,
                               primaryEngineID: String = "primary", candidateEngineID: String = "candidate") -> HarmFix {
        let referenceTokens = MixedErrorRate.tokenize(reference)
        let counts = harmFixCounts(
            base: MixedErrorRate.align(reference: referenceTokens, hypothesis: MixedErrorRate.tokenize(primary)),
            other: MixedErrorRate.align(reference: referenceTokens, hypothesis: MixedErrorRate.tokenize(candidate)))
        return HarmFix(primaryEngineID: primaryEngineID, candidateEngineID: candidateEngineID, utteranceCount: 1,
                       tokenFixes: counts.tokenFixes, tokenHarms: counts.tokenHarms,
                       insertionFixes: counts.insertionFixes, insertionHarms: counts.insertionHarms)
    }

    /// 全报告 harm/fix：两系统都已计分的句子逐句累加；任一系统未参与比较 → nil。
    public static func harmFix(report: Report, primaryEngineID: String, candidateEngineID: String) -> HarmFix? {
        let included = report.includedEngineIDs
        guard included.contains(primaryEngineID), included.contains(candidateEngineID) else { return nil }
        var utterances = 0
        var total = HarmFixCounts()
        for detail in report.utterances {
            guard let base = detail.score(for: primaryEngineID), let other = detail.score(for: candidateEngineID),
                  base.isScored, other.isScored else { continue }
            let referenceTokens = MixedErrorRate.tokenize(detail.reference)
            let baseAlignment = MixedErrorRate.align(reference: referenceTokens,
                                                     hypothesis: MixedErrorRate.tokenize(base.hypothesis ?? ""))
            let otherAlignment = MixedErrorRate.align(reference: referenceTokens,
                                                      hypothesis: MixedErrorRate.tokenize(other.hypothesis ?? ""))
            total.add(harmFixCounts(base: baseAlignment, other: otherAlignment))
            utterances += 1
        }
        return HarmFix(primaryEngineID: primaryEngineID, candidateEngineID: candidateEngineID,
                       utteranceCount: utterances, tokenFixes: total.tokenFixes, tokenHarms: total.tokenHarms,
                       insertionFixes: total.insertionFixes, insertionHarms: total.insertionHarms)
    }

    struct HarmFixCounts {
        var tokenFixes = 0
        var tokenHarms = 0
        var insertionFixes = 0
        var insertionHarms = 0

        mutating func add(_ other: HarmFixCounts) {
            tokenFixes += other.tokenFixes
            tokenHarms += other.tokenHarms
            insertionFixes += other.insertionFixes
            insertionHarms += other.insertionHarms
        }
    }

    /// 同一参考上的两条对齐 → 四项计数。
    static func harmFixCounts(base: MixedErrorRate.Result, other: MixedErrorRate.Result) -> HarmFixCounts {
        var counts = HarmFixCounts()
        let baseMatched = matchedReferenceTokens(base)
        let otherMatched = matchedReferenceTokens(other)
        for index in 0..<min(baseMatched.count, otherMatched.count) {
            if !baseMatched[index] && otherMatched[index] { counts.tokenFixes += 1 }
            if baseMatched[index] && !otherMatched[index] { counts.tokenHarms += 1 }
        }
        let baseGaps = insertionsPerGap(base)
        let otherGaps = insertionsPerGap(other)
        for gap in 0..<min(baseGaps.count, otherGaps.count) {
            let delta = otherGaps[gap] - baseGaps[gap]
            if delta > 0 { counts.insertionHarms += delta } else { counts.insertionFixes -= delta }
        }
        return counts
    }

    /// 每个参考 token 是否被原样匹配。
    static func matchedReferenceTokens(_ result: MixedErrorRate.Result) -> [Bool] {
        var matched = [Bool](repeating: false, count: result.referenceLength)
        for pair in result.alignment where pair.operation == .match {
            if let index = pair.referenceIndex { matched[index] = true }
        }
        return matched
    }

    /// 每个参考间隙（0…n）内的插入数。
    static func insertionsPerGap(_ result: MixedErrorRate.Result) -> [Int] {
        var gaps = [Int](repeating: 0, count: result.referenceLength + 1)
        var consumed = 0
        for pair in result.alignment {
            if pair.operation == .insertion {
                gaps[consumed] += 1
            } else if pair.referenceIndex != nil {
                consumed += 1
            }
        }
        return gaps
    }
}
