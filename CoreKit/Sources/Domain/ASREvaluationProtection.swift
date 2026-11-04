import Foundation

/// 保护类（round3 §6.1 第 7 步 / P2「保护类新增错误 0」）：参考中的**数字、否定词、调用方指定的
/// 保护词（药名等）**——评测只问一件事：假设是否**原样保留**（逐 token 对齐判定，见
/// `MixedErrorRate.Result.preserves(referenceRange:)`）。
extension ASREvaluation {

    public enum ProtectedKind: String, Sendable, Codable, CaseIterable {
        /// 阿拉伯数字 token（中文数字请写进 `protectedTerms`）。
        case numeric
        /// 否定标记（词表见 `negationMarkers` / `englishNegations`）。
        case negation
        /// 清单 `protectedTerms`。
        case protectedTerm
    }

    /// 参考中的一个保护区间（token 下标，半开区间 `[tokenStart, tokenStart + tokenCount)`）。
    public struct ProtectedSpan: Sendable, Equatable, Codable {
        public var kind: ProtectedKind
        public var tokenStart: Int
        public var tokenCount: Int
        /// 参考侧原文（归一后 token 拼接）。
        public var text: String

        public init(kind: ProtectedKind, tokenStart: Int, tokenCount: Int, text: String) {
            self.kind = kind
            self.tokenStart = tokenStart
            self.tokenCount = tokenCount
            self.text = text
        }

        public var tokenRange: Range<Int> { tokenStart ..< tokenStart + tokenCount }
    }

    /// 中文否定标记（按字计 token 后逐字判定）。不收「莫」——与药名「阿莫西林」冲突。
    static let negationMarkers: Set<String> = ["不", "没", "别", "未", "无", "非", "勿", "否"]

    /// 标记字在其中**不表否定**的常见双字词（「非常」「是否」「性别」……）；只排这些，宁多勿漏。
    static let nonNegatingCompounds: Set<String> = [
        "非常", "是否", "无论", "未来",
        "特别", "区别", "分别", "性别", "告别", "差别", "级别", "类别", "个别", "识别", "鉴别", "辨别", "判别",
        "别人", "别的", "别处",
    ]

    /// 英文否定词（小写；撇号为 ASCII，含常见无撇号拼法）。
    static let englishNegations: Set<String> = [
        "no", "not", "never", "none", "nothing", "nobody", "nowhere", "neither", "nor", "without",
        "cannot", "can't", "don't", "doesn't", "didn't", "isn't", "aren't", "wasn't", "weren't", "won't",
        "wouldn't", "couldn't", "shouldn't", "haven't", "hasn't", "hadn't", "mustn't",
        "cant", "dont", "doesnt", "didnt", "isnt", "arent", "wasnt", "werent", "wouldnt", "couldnt",
        "shouldnt", "havent", "hasnt", "hadnt",
        "deny", "denies", "denied",
    ]

    /// 参考 token 中的全部保护区间，按（起点，类别声明序）稳定排序。
    public static func protectedSpans(in reference: [MixedErrorRate.Token],
                                      protectedTerms: [String] = []) -> [ProtectedSpan] {
        var spans: [ProtectedSpan] = []
        for (index, token) in reference.enumerated() {
            if token.kind == .number {
                spans.append(ProtectedSpan(kind: .numeric, tokenStart: index, tokenCount: 1, text: token.text))
            }
            if isNegation(at: index, in: reference) {
                spans.append(ProtectedSpan(kind: .negation, tokenStart: index, tokenCount: 1, text: token.text))
            }
        }
        var seenTerms = Set<[MixedErrorRate.Token]>()
        for term in protectedTerms {
            let termTokens = MixedErrorRate.tokenize(term)
            guard !termTokens.isEmpty, seenTerms.insert(termTokens).inserted else { continue }
            for start in occurrences(of: termTokens, in: reference) {
                spans.append(ProtectedSpan(kind: .protectedTerm, tokenStart: start, tokenCount: termTokens.count,
                                           text: MixedErrorRate.joined(termTokens)))
            }
        }
        let order = Dictionary(uniqueKeysWithValues: ProtectedKind.allCases.enumerated().map { ($1, $0) })
        return spans.sorted { lhs, rhs in
            if lhs.tokenStart != rhs.tokenStart { return lhs.tokenStart < rhs.tokenStart }
            if lhs.kind != rhs.kind { return (order[lhs.kind] ?? 0) < (order[rhs.kind] ?? 0) }
            return lhs.tokenCount < rhs.tokenCount
        }
    }

    /// `needle` 在 `haystack` 中的全部不重叠出现位置（从左到右，按 token 文本比较）。
    static func occurrences(of needle: [MixedErrorRate.Token], in haystack: [MixedErrorRate.Token]) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var starts: [Int] = []
        var index = 0
        while index + needle.count <= haystack.count {
            var hit = true
            for offset in 0..<needle.count where haystack[index + offset].text != needle[offset].text {
                hit = false
                break
            }
            if hit {
                starts.append(index)
                index += needle.count
            } else {
                index += 1
            }
        }
        return starts
    }

    static func isNegation(at index: Int, in tokens: [MixedErrorRate.Token]) -> Bool {
        let token = tokens[index]
        switch token.kind {
        case .word:
            return englishNegations.contains(token.text)
        case .cjk:
            guard negationMarkers.contains(token.text) else { return false }
            if index > 0, tokens[index - 1].kind == .cjk,
               nonNegatingCompounds.contains(tokens[index - 1].text + token.text) { return false }
            if index + 1 < tokens.count, tokens[index + 1].kind == .cjk,
               nonNegatingCompounds.contains(token.text + tokens[index + 1].text) { return false }
            return true
        case .number:
            return false
        }
    }
}
