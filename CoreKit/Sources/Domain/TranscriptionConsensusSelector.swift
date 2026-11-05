import Foundation

/// 生产文本一致性选择器（业主 2026-11-05 裁决：保守选择器 + 默认门控）。
///
/// 只做**替换**，不生成、不插入、不删除：
/// - 至少 `minimumAgreement` 个副源在同一对齐列给出与主轨不同的同一等价键；
/// - 主轨词元与任一参与副源词元都不是受保护类（数字/单位/否定/调用方词条/极性）；
/// - 替换文本必须来自某个副源的原样 surface；
/// - 不动标点/分隔符——只替换主轨词元的 UTF-16 区间。
///
/// 不依赖校准表/金样（与 `HypothesisFusion` 的 gatedRewrite 分开）；仍输出 D 级草稿，
/// 不改变 BR-003/004/006。词表/受保护类由调用方注入。
public struct TranscriptionConsensusEdit: Sendable, Equatable {
    /// 相对主轨 `text` 的 UTF-16 区间。
    public var range: Range<Int>
    public var original: String
    public var replacement: String
    /// 支持该候选的副源 engineID（按输入顺序去重）。
    public var supporters: [String]

    public init(range: Range<Int>, original: String, replacement: String, supporters: [String]) {
        self.range = range
        self.original = original
        self.replacement = replacement
        self.supporters = supporters
    }
}

public struct TranscriptionConsensusResult: Sendable, Equatable {
    public var text: String
    public var edits: [TranscriptionConsensusEdit]
    /// 因受保护类/极性而拒绝改写的列数（诊断用，不交付）。
    public var protectedColumns: Int

    public init(text: String, edits: [TranscriptionConsensusEdit], protectedColumns: Int) {
        self.text = text
        self.edits = edits
        self.protectedColumns = protectedColumns
    }
}

public enum TranscriptionConsensusSelector {
    /// 生产默认：两源一致才改；最多取 4 个副源，避免同源多实例放大。
    public static let minimumAgreement = 2
    public static let maximumSecondaries = 4

    /// 从一次按压结果选择最终文本；无可用副源/无一致/受保护时原样返回。
    public static func select(_ result: TranscriptionResult,
                              policy: HypothesisFusionPolicy,
                              minimumAgreement: Int = minimumAgreement) -> TranscriptionResult {
        let primary: TranscriptionHypothesis
        if let matched = result.hypotheses.first(where: { $0.engineID == result.engineID }) {
            primary = matched
        } else {
            primary = TranscriptionHypothesis(
                engineID: result.engineID ?? "primary",
                localeIdentifier: result.resolvedLocale, text: result.text)
        }
        var seen = Set<String>([primary.engineID])
        let secondaries = result.hypotheses.filter { hypothesis in
            guard hypothesis.engineID != primary.engineID,
                  !hypothesis.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(hypothesis.engineID).inserted else { return false }
            return true
        }.prefix(maximumSecondaries)
        let consensus = select(primary: primary, secondaries: Array(secondaries),
                               policy: policy, minimumAgreement: minimumAgreement)
        guard consensus.text != result.text else { return result }
        var selected = result
        selected.text = consensus.text
        return selected
    }

    /// 纯函数：主轨 + 副源 → 替换后的文本与编辑证据。
    public static func select(primary: TranscriptionHypothesis,
                              secondaries: [TranscriptionHypothesis],
                              policy: HypothesisFusionPolicy,
                              minimumAgreement: Int = minimumAgreement) -> TranscriptionConsensusResult {
        let threshold = max(2, minimumAgreement)
        let primaryTokens = HypothesisFusionTokenizer.tokenize(primary.text, policy: policy)
        guard !primaryTokens.isEmpty, !secondaries.isEmpty else {
            return TranscriptionConsensusResult(text: primary.text, edits: [], protectedColumns: 0)
        }

        var seen = Set<String>([primary.engineID])
        let uniqueSecondaries = secondaries.filter { hypothesis in
            guard !hypothesis.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(hypothesis.engineID).inserted else { return false }
            return true
        }.prefix(maximumSecondaries)
        var voters: [String] = []
        var columns = HypothesisFusionAligner.skeleton(primaryTokens)
        for secondary in uniqueSecondaries {
            let tokens = HypothesisFusionTokenizer.tokenize(secondary.text, policy: policy)
            guard !tokens.isEmpty else { continue }
            guard (columns.count + 1) * (tokens.count + 1) <= HypothesisFusion.maximumAlignmentCells else {
                return TranscriptionConsensusResult(text: primary.text, edits: [], protectedColumns: 0)
            }
            columns = HypothesisFusionAligner.merge(columns, engineIndex: voters.count + 1, tokens: tokens)
            voters.append(secondary.engineID)
        }
        guard voters.count >= threshold else {
            return TranscriptionConsensusResult(text: primary.text, edits: [], protectedColumns: 0)
        }

        var edits: [TranscriptionConsensusEdit] = []
        var protectedColumns = 0
        for column in columns {
            guard let primaryIndex = column.primaryIndex,
                  primaryTokens.indices.contains(primaryIndex) else { continue }
            let anchor = column.anchor
            guard !anchor.isProtected, anchor.tokenClass != .polarity else {
                protectedColumns += 1
                continue
            }
            var counts: [String: (count: Int, surface: String, supporters: [String])] = [:]
            var columnProtected = false
            for (offset, vote) in column.votes.dropFirst().enumerated() {
                guard let token = vote.token else { continue }
                if token.isProtected || token.tokenClass == .polarity {
                    columnProtected = true
                    break
                }
                guard token.key != anchor.key else { continue }
                let engine = offset < voters.count ? voters[offset] : "secondary-\(offset)"
                if var entry = counts[token.key] {
                    entry.count += 1
                    if !entry.supporters.contains(engine) { entry.supporters.append(engine) }
                    counts[token.key] = entry
                } else {
                    counts[token.key] = (1, token.surface, [engine])
                }
            }
            if columnProtected {
                protectedColumns += 1
                continue
            }
            guard let winner = counts.values
                .filter({ $0.count >= threshold })
                .sorted(by: { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.surface.utf8.lexicographicallyPrecedes(rhs.surface.utf8)
                })
                .first else { continue }
            guard winner.surface != anchor.surface else { continue }
            let range = anchor.utf16Range
            guard range.lowerBound >= 0, range.upperBound <= primary.text.utf16.count else { continue }
            edits.append(TranscriptionConsensusEdit(range: range, original: anchor.surface,
                                                    replacement: winner.surface,
                                                    supporters: winner.supporters))
        }
        guard !edits.isEmpty else {
            return TranscriptionConsensusResult(text: primary.text, edits: [], protectedColumns: protectedColumns)
        }

        var text = primary.text
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let nsRange = NSRange(location: edit.range.lowerBound, length: edit.range.count)
            guard let swiftRange = Range(nsRange, in: text) else { continue }
            text.replaceSubrange(swiftRange, with: edit.replacement)
        }
        return TranscriptionConsensusResult(text: text, edits: edits, protectedColumns: protectedColumns)
    }
}
