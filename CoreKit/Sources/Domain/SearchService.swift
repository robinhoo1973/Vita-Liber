import Foundation

/// F12 搜索语义（§5.30 / §4.3 V3.24 查询长度路由）：
/// ≥3 字 trigram 主表 / 2 字 2-gram 影子表 / 1 字 LIKE 兜底（低频高噪音，
/// 限定 member+时间窗缩小扫描集）。Domain 持有路由与校验，FTS 执行归 Infrastructure。
public struct SearchQuery: Sendable, Equatable {
    public var text: String
    public var member: UUID?
    public var docKinds: Set<String>?
    public var dateRange: DateInterval?
    public var includeArchived: Bool
    public init(text: String, member: UUID? = nil, docKinds: Set<String>? = nil,
                dateRange: DateInterval? = nil, includeArchived: Bool = false) {
        self.text = text
        self.member = member
        self.docKinds = docKinds
        self.dateRange = dateRange
        self.includeArchived = includeArchived
    }
}

public struct SearchHit: Sendable, Equatable {
    public var docID: UUID
    public var snippet: String
    public var field: String
    public var date: Date
    public init(docID: UUID, snippet: String, field: String, date: Date) {
        self.docID = docID; self.snippet = snippet; self.field = field; self.date = date
    }
}

public enum SearchRoute: Sendable, Equatable {
    case trigram          // ≥3 字：document_fts 主表
    case bigram           // 2 字：document_fts_2gram 影子表
    case like             // 1 字：LIKE '%x%' 兜底（低频高噪音）
    case invalid
}

public enum SearchRules {
    /// 查询长度按「非空白字符数」（CJK 与拉丁混排均可路由——评审修正：
    /// 纯拉丁查询不得 invalid；trigram tokenizer 对拉丁词同样生效）
    public static func cjkLength(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }

    /// 查询长度路由（V3.24）：≥3 字 trigram / 2 字 bigram / 1 字 LIKE / 空查询 invalid
    public static func route(_ text: String) -> SearchRoute {
        let n = cjkLength(text.trimmingCharacters(in: .whitespaces))
        switch n {
        case 0: return .invalid
        case 1: return .like
        case 2: return .bigram
        default: return .trigram
        }
    }

    /// 2-gram 切分（bigram 影子表写入侧同构）：连续 CJK 2 字序列空格分隔
    public static func bigrams(_ text: String) -> [String] {
        let chars = Array(text)
        guard chars.count >= 2 else { return [] }
        // 显式循环而非闭包链式映射：Swift 6.0 的类型检查器对
        // `String(chars[$0]) + String(chars[$0+1])` 的隐式类型推断超时
        // （本地 6.3 宽容通过、CI 6.0 报 type-check 超时——ERR#26b 同族：
        // 本地与 CI 主版本差 ≥1 时以 CI 为准）
        var result: [String] = []
        result.reserveCapacity(chars.count - 1)
        for index in 0..<(chars.count - 1) {
            let pair = String(chars[index]) + String(chars[index + 1])
            result.append(pair)
        }
        return result
    }

    /// 高亮片段：命中词在片段中的首现位置（snippet 生成由 FTS snippet 函数承担，
    /// Domain 侧提供「敏感媒体只命中元数据」规则）
    public static func isSensitiveDoc(_ docKind: String) -> Bool {
        docKind == "sensitive_photo" || docKind == "sensitive_media"
    }

    /// contentless FTS 表无 snippet 函数——检索侧取回源列后手动高亮（V3.44）
    public static func highlight(_ text: String?, query: String) -> String {
        guard let text, !text.isEmpty else { return "" }
        guard let range = text.range(of: query) else {
            return String(text.prefix(40))
        }
        let leadCount = min(12, text.distance(from: text.startIndex, to: range.lowerBound))
        let lower = text.index(range.lowerBound, offsetBy: -leadCount)
        let trailCount = min(24, text.distance(from: range.upperBound, to: text.endIndex))
        let upper = text.index(range.upperBound, offsetBy: trailCount)
        let lead = lower > text.startIndex ? "…" : ""
        let trail = upper < text.endIndex ? "…" : ""
        return lead + text[lower..<range.lowerBound] + "<b>" + query + "</b>" + text[range.upperBound..<upper] + trail
    }
}
