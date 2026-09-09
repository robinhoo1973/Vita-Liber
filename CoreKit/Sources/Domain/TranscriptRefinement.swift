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
    /// Dictionaries are not a safety boundary: every source byte is protected.
    /// Only ASCII-space run normalization and one terminal full stop after a letter are allowed.
    /// Tabs/newlines, lexical boundaries, interior punctuation and existing terminal marks stay exact.
    public static func validate(original: String, suggested: String,
                                drugNames _: [String] = [], personNames _: [String] = []) -> RefinementSafety {
        guard original.contains(where: { !$0.isWhitespace }),
              WordingBlacklist.violation(in: suggested) == nil else { return .rejected }
        let source = normalizedSpaces(original)
        if source == normalizedSpaces(suggested) { return .accepted }
        // Never turn a question/ellipsis into a statement or a trailing number into a decimal.
        guard let last = original.unicodeScalars.last, CharacterSet.letters.contains(last),
              suggested.hasSuffix(".") || suggested.hasSuffix("。") else { return .rejected }
        return source == normalizedSpaces(String(suggested.dropLast())) ? .accepted : .rejected
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
