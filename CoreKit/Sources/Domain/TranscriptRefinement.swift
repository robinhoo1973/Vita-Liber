import Foundation

/// FR17.9/FR17.18（V3.61 实装）端侧润色双版本安全合同：润色只做**非医疗、非事实扩写**的
/// 语言清理（断句、标点、明显同音错字）；原文永远保留；建议输出为并列 D 级，用户显式选用。
/// `ProtectedTokenValidator` 逐 token 比较数值、单位、日期、否定词、药名、人名——任一缺失
/// 或改变即 `.rejected` 回原文（BR-003 不改事实 / BR-006 不改语义）。纯 Domain、零依赖。
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
        self.original = original; self.suggested = suggested; self.safety = safety
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
    /// 否定词（中文医疗口语高频；缺失/新增任一即改变语义）
    static let negations: [String] = ["没有", "不再", "未", "无", "没", "不", "别", "勿", "非"]
    /// 常见医疗单位（词表偏置同源，不含阈值）
    static let units: [String] = ["mmHg", "mmol/L", "mg/dL", "g/L", "bpm", "kg", "cm", "℃", "IU", "mg", "ml", "μg", "%"]

    /// 抽取受保护 token（多重集，保持出现顺序）：日期串、数字、单位、否定词、药名、人名。
    public static func protectedTokens(in text: String, drugNames: [String] = [],
                                       personNames: [String] = []) -> [String] {
        var tokens: [String] = []
        var scanned = text
        // 1. 日期（整串保护，避免被拆成多个数字后只比较集合）
        for date in matches(#"\d{4}\s*[-/年.]\s*\d{1,2}\s*[-/月.]\s*\d{1,2}日?"#, in: scanned) {
            tokens.append(date.replacingOccurrences(of: " ", with: ""))
            scanned = scanned.replacingOccurrences(of: date, with: " ")
        }
        // 2. 单位（先于数字，防「mmol/L」被拆）
        for unit in units where scanned.contains(unit) {
            let count = scanned.components(separatedBy: unit).count - 1
            tokens += Array(repeating: unit, count: count)
            scanned = scanned.replacingOccurrences(of: unit, with: " ")
        }
        // 3. 数字（含小数）
        tokens += matches(#"\d+(?:\.\d+)?"#, in: scanned)
        // 4. 药名 / 人名（用户词表，整词保护）
        for name in drugNames + personNames where !name.isEmpty {
            let count = text.components(separatedBy: name).count - 1
            tokens += Array(repeating: name, count: count)
        }
        // 5. 否定词（长词优先，避免「没有」再计一次「没」）
        var negScan = text
        for negation in negations.sorted { $0.count > $1.count } where negScan.contains(negation) {
            let count = negScan.components(separatedBy: negation).count - 1
            tokens += Array(repeating: negation, count: count)
            negScan = negScan.replacingOccurrences(of: negation, with: " ")
        }
        return tokens
    }

    /// 校验：原文与建议的受保护 token 多重集必须完全一致（顺序无关、数量相关）。
    public static func validate(original: String, suggested: String,
                                drugNames: [String] = [], personNames: [String] = []) -> RefinementSafety {
        let before = protectedTokens(in: original, drugNames: drugNames, personNames: personNames)
        let after = protectedTokens(in: suggested, drugNames: drugNames, personNames: personNames)
        return multiset(before) == multiset(after) ? .accepted : .rejected
    }

    private static func multiset(_ tokens: [String]) -> [String: Int] {
        tokens.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }   // try?-ok: 静态字面量，构造不会失败
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
