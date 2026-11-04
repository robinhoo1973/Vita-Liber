import Foundation

/// 一个引擎在某列的票：词元或 ∅（该引擎在此处无内容）。
enum HypothesisFusionVote: Equatable {
    case token(HypothesisFusionToken)
    case null

    var token: HypothesisFusionToken? {
        if case .token(let token) = self { return token }
        return nil
    }
}

/// 混淆网络的一列（ROVER 词转移网络的一个槽）。
struct HypothesisFusionColumn: Equatable {
    /// 参照词元：主轨列 = 主轨词元；插入列 = 建列的副轨词元。列脚本/词类（弃权与校准维度）都取它。
    var anchor: HypothesisFusionToken
    /// 主轨词元下标；nil = 插入列（主轨在此隐含 ∅）。
    var primaryIndex: Int?
    /// 按引擎顺序（0 = 主轨，其后为排序后的副轨）的票。
    var votes: [HypothesisFusionVote]

    var isInsertion: Bool { primaryIndex == nil }
}

/// 以主轨为骨架、带 NULL 的 DP 对齐（round3 §6.1 步骤 2/3；沿用 `CharacterErrorRate` 的编辑距离写法）。
///
/// 副轨按引擎顺序逐个并入：每个副轨与「当前网络」做 DP，其多出的词元另建插入列，供后续副轨匹配
/// （经典 ROVER 渐进合并；顺序由调用方按 engineID 排序固定，故结果与输入顺序无关）。
///
/// 代价以 ×100 的整数表示，平局判定无浮点误差；回溯指针在前向计算时按固定优先级
/// （对角 > 跳过列 > 插入）记录，同输入必得同路径。
/// 同音（拼音相同）/ 跨脚本前缀只**降低**替换代价、让它们落在同一列，绝不令其成为同一候选。
enum HypothesisFusionAligner {
    static let matchCost = 0
    static let homophoneCost = 35
    static let crossScriptPrefixCost = 60
    static let substitutionCost = 100
    /// 副轨跳过主轨列（此处投 ∅）或多出一个词元（建插入列）。
    static let gapCost = 90
    /// 副轨跳过既有插入列：主轨在此本就为 ∅，不计代价。
    static let skipInsertionCost = 0

    private enum Step: UInt8 {
        case none = 0
        case diagonal
        case skipColumn
        case insertToken
    }

    static func skeleton(_ primary: [HypothesisFusionToken]) -> [HypothesisFusionColumn] {
        primary.enumerated().map { offset, token in
            HypothesisFusionColumn(anchor: token, primaryIndex: offset, votes: [.token(token)])
        }
    }

    /// 两词元的对齐软代价：键同 0；拼音同 35；跨脚本且拼音互为前缀（≥2 字母）60；其余 100。
    static func cost(_ lhs: HypothesisFusionToken, _ rhs: HypothesisFusionToken) -> Int {
        if lhs.key == rhs.key { return matchCost }
        if !lhs.phonetic.isEmpty, lhs.phonetic == rhs.phonetic { return homophoneCost }
        if lhs.script != rhs.script, min(lhs.phonetic.count, rhs.phonetic.count) >= 2,
           lhs.phonetic.hasPrefix(rhs.phonetic) || rhs.phonetic.hasPrefix(lhs.phonetic) {
            return crossScriptPrefixCost
        }
        return substitutionCost
    }

    /// 把第 `engineIndex` 个引擎的词元并入网络；返回的每列票数 = `engineIndex + 1`。
    static func merge(_ columns: [HypothesisFusionColumn], engineIndex: Int,
                      tokens: [HypothesisFusionToken]) -> [HypothesisFusionColumn] {
        let rows = columns.count
        let width = tokens.count + 1
        let references: [[HypothesisFusionToken]] = columns.map { column in
            guard column.isInsertion else { return [column.anchor] }
            var seen = Set<String>()
            var distinct: [HypothesisFusionToken] = []
            for vote in column.votes {
                if let token = vote.token, seen.insert(token.key).inserted { distinct.append(token) }
            }
            return distinct
        }
        var total = [Int](repeating: 0, count: (rows + 1) * width)
        var steps = [Step](repeating: .none, count: (rows + 1) * width)
        for row in 0...rows {
            for column in 0..<width where row > 0 || column > 0 {
                var best = Int.max
                var step = Step.none
                if row > 0, column > 0 {
                    let pair = references[row - 1].map { cost($0, tokens[column - 1]) }.min() ?? substitutionCost
                    let candidate = total[(row - 1) * width + column - 1] + pair
                    if candidate < best { best = candidate; step = .diagonal }
                }
                if row > 0 {
                    let skip = columns[row - 1].isInsertion ? skipInsertionCost : gapCost
                    let candidate = total[(row - 1) * width + column] + skip
                    if candidate < best { best = candidate; step = .skipColumn }
                }
                if column > 0 {
                    let candidate = total[row * width + column - 1] + gapCost
                    if candidate < best { best = candidate; step = .insertToken }
                }
                total[row * width + column] = best
                steps[row * width + column] = step
            }
        }
        var path: [(step: Step, row: Int, column: Int)] = []
        var row = rows
        var column = tokens.count
        while row > 0 || column > 0 {
            var step = steps[row * width + column]
            if step == .none {
                // 不可达（除原点外每格必有前驱）；防御性收敛，绝不越界、不丢词元。
                step = row > 0 ? .skipColumn : .insertToken
            }
            path.append((step, row, column))
            switch step {
            case .diagonal:
                row -= 1
                column -= 1
            case .skipColumn, .none:
                row -= 1
            case .insertToken:
                column -= 1
            }
        }
        var merged: [HypothesisFusionColumn] = []
        merged.reserveCapacity(rows + tokens.count)
        for entry in path.reversed() {
            switch entry.step {
            case .diagonal:
                var updated = columns[entry.row - 1]
                updated.votes.append(.token(tokens[entry.column - 1]))
                merged.append(updated)
            case .skipColumn, .none:
                var updated = columns[entry.row - 1]
                updated.votes.append(.null)
                merged.append(updated)
            case .insertToken:
                let token = tokens[entry.column - 1]
                let votes = [HypothesisFusionVote](repeating: .null, count: engineIndex) + [.token(token)]
                merged.append(HypothesisFusionColumn(anchor: token, primaryIndex: nil, votes: votes))
            }
        }
        return merged
    }
}
