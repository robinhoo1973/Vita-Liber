import Foundation

/// FR17.9/FR17.18: format-only D-grade suggestions, never factual or lexical rewriting.
/// BR-003/BR-006: preserve the ordered source, operators, punctuation and word/line boundaries.
public enum RefinementSafety: String, Sendable, Codable, Equatable {
    case accepted      // 通过校验，可作「LLM 修正版」呈现（D 级）
    case rejected      // 受保护 token 被改，回原文
    case unavailable   // 本机无模型/未授权/平台不支持
    case timedOut      // 超时（1.5s），回原文
}

public struct TranscriptRevision: Sendable, Equatable {
    public let original: String
    public let suggested: String
    public let safety: RefinementSafety
    public init(original: String, suggested: String, safety: RefinementSafety) {
        self.original = original
        self.suggested = suggested
        self.safety = safety == .accepted
            ? ProtectedTokenValidator.validate(original: original, suggested: suggested)
            : safety
    }
    /// 生效文本：只有 accepted 才是建议；其余一律原文
    public var effective: String { safety == .accepted ? suggested : original }
    public static func unavailable(_ original: String) -> TranscriptRevision {
        TranscriptRevision(original: original, suggested: original, safety: .unavailable)
    }
    public static func timedOut(_ original: String) -> TranscriptRevision {
        TranscriptRevision(original: original, suggested: original, safety: .timedOut)
    }
}

public enum ProtectedTokenValidator {
    /// 可插入标点白名单（业主 2026-09-19「语音识别文本缺标点」修正）：
    /// **仅句末终止符**（。！？及 ASCII 同形）——句末标点只结句、不改任何
    /// token 的否定辖域；**逗号/顿号/分号等句内标点仍禁插**（「没有发热
    /// 咳嗽」→「没有发热，咳嗽」会把「咳嗽」从否定辖域划出——语义已变，
    /// BR-003/BR-006 不可接受；既有测试 `boundariesPunctuationAnd…` 族
    /// 钉死该判例）。逐字节可验证：原文（空白归并后）必须等于建议文本
    /// 剥除可插入标点后的字节序列——即「只插入、不改写、不删除」。
    private static let insertablePunctuation: Set<Character> = Set("。！？.!?")

    /// Dictionaries are not a safety boundary: every source byte is protected.
    /// Only ASCII-space run normalization and insertion of sentence-terminal
    /// punctuation are allowed. Tabs/newlines, lexical boundaries, interior
    /// punctuation and existing terminal marks stay exact.
    public static func validate(original: String, suggested: String,
                                drugNames _: [String] = [], personNames _: [String] = []) -> RefinementSafety {
        guard original.contains(where: { !$0.isWhitespace }),
              WordingBlacklist.violation(in: suggested) == nil else { return .rejected }
        let source = normalizedSpaces(original)
        // 原样未改恒放行（空白归并相等即未改——「No cough?」原样返回不得被
        // 剥除校验误伤：原文自带的「?」在剥除侧不参与比较）。
        if source == normalizedSpaces(suggested) { return .accepted }
        let candidate = Array(strippedInsertables(normalizedSpacesText(suggested)).utf8)
        guard candidate == source else { return .rejected }
        // 数字相邻禁插：314 → 3.14 / 3 50 → 3:50 语义已变（数值防篡改）。
        guard !insertsPunctuationBetweenDigits(suggested) else { return .rejected }
        return .accepted
    }

    /// 剥除可插入标点（Character 级——「。」等 CJK 标点为多字节 UTF-8，
    /// 字节级过滤永远剥不掉，必须按 Character 过滤）。
    private static func strippedInsertables(_ text: String) -> String {
        String(text.filter { !insertablePunctuation.contains($0) })
    }

    /// 空白归并的字符串形态（剥除标点的中间产物用；字节形态见 normalizedSpaces）。
    private static func normalizedSpacesText(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar.value == 0x20, out.unicodeScalars.last?.value == 0x20 { continue }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// 可插入标点不得与数字相邻（含**行尾位置**——「值5」+「。」读作
    /// 小数；314 + 「.」变 3.14）：任一侧相邻标量是 ASCII/全宽数字即拒绝。
    /// 注意只对**插入位**判定——原文自带标点不经过本函数（strip 相等性
    /// 已保证原文标点原样保留）。
    private static func insertsPunctuationBetweenDigits(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        for index in scalars.indices {
            guard insertablePunctuation.contains(Character(scalars[index])) else { continue }
            if isDigit(scalars[safe: index - 1]) || isDigit(scalars[safe: index + 1]) { return true }
        }
        return false
    }

    private static func isDigit(_ scalar: UnicodeScalar?) -> Bool {
        guard let scalar else { return false }
        return (0x30...0x39).contains(scalar.value)          // ASCII 0-9
            || (0xFF10...0xFF19).contains(scalar.value)      // 全宽 ０-９
    }

    private static func normalizedSpaces(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for byte in text.utf8 {
            if byte == 0x20, bytes.last == 0x20 { continue }
            bytes.append(byte)
        }
        return bytes
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
