import Foundation

/// 混合错误率 MER（Mixed Error Rate）：中英混说识别的评测口径
/// （round3 §8 P0-A 杀手实验 / P2 指标表「汉字按字 + 英文按词」）。
///
/// **计量单位**：
/// - 汉字（CJK 统一表意文字含扩展区、〇、々）与假名：**按字**，一字一 token；
/// - 拉丁等字母文字：**按词**（连续字母为一词，统一小写；词内撇号保留：`don't`）；
/// - 阿拉伯数字：**整体**为一 token，含一个小数点（`37.5`）与标准千分位（`1,000` → `1000`）。
///
/// **归一**：先 NFKC（全角→半角、兼容字符分解：「５００ｍｇ」→「500mg」），弯撇号折为 `'`；
/// 标点、符号、空白只作分隔、不计 token。中文数字（「五百」）按字计——与「500」不等价：
/// 评测口径是「字面原样」，ITN 差异如实计错（数值等价是融合层的比较键，不是评测口径）。
///
/// **对齐**：单位代价 Levenshtein；最小代价路径不唯一时取**匹配数最多**者，再按
/// 「对角 > 删除 > 插入」固定次序破平——同输入恒得同一路径，供保护类（数字/否定/药名）
/// 逐 token 判定「是否原样保留」。
///
/// ADR-025 / FR0.1：Foundation 只提供 NFKC（`precomposedStringWithCompatibilityMapping`），
/// 无分词、编辑距离、对齐 API（与 `CharacterErrorRate` 同一审查结论），故分词与 DP 自研；纯函数、确定性。
public enum MixedErrorRate {

    /// 一个计量单位。
    public struct Token: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Hashable, Codable {
            /// 汉字/假名，一字一 token。
            case cjk
            /// 字母词（已小写）。
            case word
            /// 阿拉伯数字串（含小数点，千分位已去除）。
            case number
        }

        public var text: String
        public var kind: Kind

        public init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    /// 对齐路径上的一步。
    public enum EditOperation: String, Sendable, Codable {
        case match
        case substitution
        /// 参考有、假设无。
        case deletion
        /// 假设多出。
        case insertion
    }

    /// 对齐路径上的一对：`referenceIndex` / `hypothesisIndex` 为各自 token 序号；插入无参考侧、删除无假设侧。
    public struct AlignedPair: Sendable, Equatable, Codable {
        public var operation: EditOperation
        public var referenceIndex: Int?
        public var hypothesisIndex: Int?

        public init(operation: EditOperation, referenceIndex: Int?, hypothesisIndex: Int?) {
            self.operation = operation
            self.referenceIndex = referenceIndex
            self.hypothesisIndex = hypothesisIndex
        }
    }

    /// 一句的计量结果。
    public struct Result: Sendable, Equatable, Codable {
        public var referenceTokens: [Token]
        public var hypothesisTokens: [Token]
        /// 逐 token 对齐路径（按参考/假设顺序）。
        public var alignment: [AlignedPair]
        public var matches: Int
        public var substitutions: Int
        public var deletions: Int
        public var insertions: Int

        public init(referenceTokens: [Token], hypothesisTokens: [Token], alignment: [AlignedPair]) {
            self.referenceTokens = referenceTokens
            self.hypothesisTokens = hypothesisTokens
            self.alignment = alignment
            var counts = [EditOperation: Int]()
            for pair in alignment { counts[pair.operation, default: 0] += 1 }
            matches = counts[.match] ?? 0
            substitutions = counts[.substitution] ?? 0
            deletions = counts[.deletion] ?? 0
            insertions = counts[.insertion] ?? 0
        }

        public var referenceLength: Int { referenceTokens.count }
        public var errorCount: Int { substitutions + deletions + insertions }

        /// 错误数 / 参考 token 数（可 > 1：插入不设上限）。参考为空：假设也空 → 0，否则 1
        /// （与 `CharacterErrorRate.rate` 同口径，避免除零且如实记全错）。
        public var rate: Double {
            guard referenceLength > 0 else { return hypothesisTokens.isEmpty ? 0 : 1 }
            return Double(errorCount) / Double(referenceLength)
        }

        /// 参考区间内的 token 是否在假设中**原样保留**：区间内每个参考 token 都是 `.match`，
        /// 且区间内部没有插入（「阿莫西林」→「阿莫X西林」不算保留）。空区间/越界 → false。
        public func preserves(referenceRange range: Range<Int>) -> Bool {
            guard let window = pathWindow(for: range), window.count == range.count else { return false }
            for (offset, position) in window.enumerated() {
                let pair = alignment[position]
                guard pair.operation == .match, pair.referenceIndex == range.lowerBound + offset else { return false }
            }
            return true
        }

        /// 与参考区间对齐的假设片段（含区间内部的插入；全删除 → 空串），供报告展示伤害现场。
        public func hypothesisText(alignedTo range: Range<Int>) -> String {
            guard let window = pathWindow(for: range) else { return "" }
            let indices = window.compactMap { alignment[$0].hypothesisIndex }
            return MixedErrorRate.joined(indices.map { hypothesisTokens[$0] })
        }

        /// 参考区间首尾 token 在对齐路径上的位置闭区间（含其间的插入步）。
        private func pathWindow(for range: Range<Int>) -> ClosedRange<Int>? {
            guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= referenceTokens.count,
                  let first = alignment.firstIndex(where: { $0.referenceIndex == range.lowerBound }),
                  let last = alignment.firstIndex(where: { $0.referenceIndex == range.upperBound - 1 }),
                  first <= last else { return nil }
            return first...last
        }
    }

    // MARK: - 计量入口

    /// 一句的 MER 计量：分词 → 对齐 → 计数。
    public static func evaluate(reference: String, hypothesis: String) -> Result {
        align(reference: tokenize(reference), hypothesis: tokenize(hypothesis))
    }

    // MARK: - 归一与分词

    /// NFKC + 弯撇号（U+2018/U+2019/U+02BC）折为 ASCII `'`。不做大小写折叠（分词时对字母词小写）。
    public static func normalize(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        var out = String.UnicodeScalarView()
        for scalar in nfkc.unicodeScalars {
            switch scalar.value {
            case 0x2018, 0x2019, 0x02BC: out.append(apostrophe)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// 按 MER 口径分词（见类型注释）。
    public static func tokenize(_ text: String) -> [Token] {
        tokenizeWithRanges(text).tokens
    }

    /// 分词结果 + 每个 token 在归一后标量序列（`normalize(text).unicodeScalars`）中的半开区间
    /// （数字区间含被折叠的千分位逗号）。供引擎逐词置信度按字符重叠映射到 MER token。
    struct RangedTokens {
        var tokens: [Token]
        var ranges: [Range<Int>]
        var scalars: [Unicode.Scalar]
    }

    static func tokenizeWithRanges(_ text: String) -> RangedTokens {
        // NFKC 会把全角逗号 U+FF0C 折成 ASCII ','，使「血压120，800」被千分位规则并成「120800」。
        // 中文全角逗号永远只是分隔符：分词前折成等长空格（标量区间仍与 normalize(text) 对齐）。
        let tokenizationInput = text.replacingOccurrences(of: "\u{FF0C}", with: " ")
        let scalars = Array(normalize(tokenizationInput).unicodeScalars)
        var tokens: [Token] = []
        var ranges: [Range<Int>] = []
        var buffer = String.UnicodeScalarView()
        var bufferKind: Token.Kind?
        var bufferStart = 0
        var bufferEnd = 0
        var numberHasPoint = false
        var digitsInGroup = 0
        var hasGrouping = false

        func flush() {
            if let kind = bufferKind, !buffer.isEmpty {
                let text = String(buffer)
                tokens.append(Token(text: kind == .word ? text.lowercased() : text, kind: kind))
                ranges.append(bufferStart ..< bufferEnd)
            }
            buffer = String.UnicodeScalarView()
            bufferKind = nil
            numberHasPoint = false
            digitsInGroup = 0
            hasGrouping = false
        }

        func extend(_ scalar: Unicode.Scalar, at index: Int, as kind: Token.Kind) {
            if bufferKind != kind {
                flush()
                bufferKind = kind
                bufferStart = index
            }
            buffer.append(scalar)
            bufferEnd = index + 1
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            defer { index += 1 }
            if isCJK(scalar) {
                flush()
                tokens.append(Token(text: String(scalar), kind: .cjk))
                ranges.append(index ..< index + 1)
            } else if isDecimalDigit(scalar) {
                extend(scalar, at: index, as: .number)
                digitsInGroup += 1
            } else if bufferKind == .number, scalar == point, !numberHasPoint,
                      index + 1 < scalars.count, isDecimalDigit(scalars[index + 1]) {
                extend(scalar, at: index, as: .number)
                numberHasPoint = true
                digitsInGroup = 0
            } else if bufferKind == .number, scalar == comma, !numberHasPoint,
                      isThousandsSeparator(in: scalars, at: index, digitsInGroup: digitsInGroup,
                                           hasGrouping: hasGrouping) {
                // 千分位：「1,000」「12,345,678」整体为一个数；「120,80」不是（两段数字，按分隔处理）。
                hasGrouping = true
                digitsInGroup = 0
                bufferEnd = index + 1
            } else if isWordScalar(scalar) {
                extend(scalar, at: index, as: .word)
            } else if bufferKind == .word, isCombiningMark(scalar) {
                extend(scalar, at: index, as: .word)
            } else if bufferKind == .word, scalar == apostrophe,
                      index + 1 < scalars.count, isWordScalar(scalars[index + 1]) {
                extend(scalar, at: index, as: .word)
            } else {
                flush()
            }
        }
        flush()
        return RangedTokens(tokens: tokens, ranges: ranges, scalars: scalars)
    }

    /// 展示用拼接：相邻两个非汉字 token 之间补一个空格（「500 mg」「vitamin d」「阿莫西林」）。
    public static func joined<C: Collection>(_ tokens: C) -> String where C.Element == Token {
        var out = ""
        var previous: Token.Kind?
        for token in tokens {
            if let previous, previous != .cjk, token.kind != .cjk { out += " " }
            out += token.text
            previous = token.kind
        }
        return out
    }

    // MARK: - 对齐（DP + 回溯）

    /// 单位代价编辑距离对齐；破平规则见类型注释。O(n·m) 时间与空间（逐句 ≤ 数百 token）。
    public static func align(reference: [Token], hypothesis: [Token]) -> Result {
        let rows = reference.count + 1
        let columns = hypothesis.count + 1
        var cost = [Int](repeating: 0, count: rows * columns)
        var matched = [Int](repeating: 0, count: rows * columns)
        var move = [Step](repeating: .start, count: rows * columns)
        for j in 1..<columns {
            cost[j] = j
            move[j] = .insertion
        }
        for i in 1..<rows {
            cost[i * columns] = i
            move[i * columns] = .deletion
            for j in 1..<columns {
                let same = reference[i - 1].text == hypothesis[j - 1].text
                let diagonal = (i - 1) * columns + (j - 1)
                let up = (i - 1) * columns + j
                let left = i * columns + (j - 1)
                var best = (cost: cost[diagonal] + (same ? 0 : 1), matched: matched[diagonal] + (same ? 1 : 0),
                            step: same ? Step.match : Step.substitution)
                if isBetter(cost[up] + 1, matched[up], than: best.cost, best.matched) {
                    best = (cost: cost[up] + 1, matched: matched[up], step: Step.deletion)
                }
                if isBetter(cost[left] + 1, matched[left], than: best.cost, best.matched) {
                    best = (cost: cost[left] + 1, matched: matched[left], step: Step.insertion)
                }
                cost[i * columns + j] = best.cost
                matched[i * columns + j] = best.matched
                move[i * columns + j] = best.step
            }
        }
        var path: [AlignedPair] = []
        var i = reference.count, j = hypothesis.count
        while i > 0 || j > 0 {
            switch move[i * columns + j] {
            case .match:
                path.append(AlignedPair(operation: .match, referenceIndex: i - 1, hypothesisIndex: j - 1))
                i -= 1; j -= 1
            case .substitution:
                path.append(AlignedPair(operation: .substitution, referenceIndex: i - 1, hypothesisIndex: j - 1))
                i -= 1; j -= 1
            case .deletion:
                path.append(AlignedPair(operation: .deletion, referenceIndex: i - 1, hypothesisIndex: nil))
                i -= 1
            case .insertion:
                path.append(AlignedPair(operation: .insertion, referenceIndex: nil, hypothesisIndex: j - 1))
                j -= 1
            case .start:
                i = 0; j = 0
            }
        }
        return Result(referenceTokens: reference, hypothesisTokens: hypothesis, alignment: Array(path.reversed()))
    }

    private enum Step: UInt8 { case start, match, substitution, deletion, insertion }

    /// 字典序：代价低者优；同代价匹配多者优；全同不替换（保住「对角 > 删除 > 插入」的先到者）。
    private static func isBetter(_ cost: Int, _ matched: Int, than bestCost: Int, _ bestMatched: Int) -> Bool {
        cost < bestCost || (cost == bestCost && matched > bestMatched)
    }

    // MARK: - 字符类

    private static let apostrophe: Unicode.Scalar = "'"
    private static let point: Unicode.Scalar = "."
    private static let comma: Unicode.Scalar = ","

    /// 汉字（基本区、扩展 A–H、兼容区、〇、々）与假名：按字计。
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3005, 0x3007,                // 々 〇
             0x3040...0x30FF,               // 平假名、片假名
             0x31F0...0x31FF,               // 片假名音标扩展
             0x3400...0x4DBF,               // 扩展 A
             0x4E00...0x9FFF,               // 基本区
             0xF900...0xFAFF,               // 兼容表意文字
             0x20000...0x323AF:             // 扩展 B–H 及兼容补充
            return true
        default:
            return false
        }
    }

    private static func isDecimalDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.numericType == .decimal
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic && !isCJK(scalar)
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// `,` 是否为千分位：当前组 1–3 位（首组）或恰 3 位（后续组），其后恰 3 位数字且不再接数字。
    private static func isThousandsSeparator(in scalars: [Unicode.Scalar], at index: Int,
                                             digitsInGroup: Int, hasGrouping: Bool) -> Bool {
        let groupOK = hasGrouping ? digitsInGroup == 3 : (1...3).contains(digitsInGroup)
        guard groupOK, index + 3 < scalars.count else { return false }
        for offset in 1...3 where !isDecimalDigit(scalars[index + offset]) { return false }
        let after = index + 4
        return after >= scalars.count || !isDecimalDigit(scalars[after])
    }
}
