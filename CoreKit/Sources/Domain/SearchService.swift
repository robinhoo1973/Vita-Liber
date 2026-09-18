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

    /// 2-gram 切分（bigram 影子表写入侧同构）：连续 CJK 2 字序列空格分隔。
    /// 审查修复：只产出「两字符均为字母/数字」的 gram——此前把分隔符/标点
    /// 相邻对也产 gram（"高 "、" 血"、"a-"），unicode61 tokenizer 剥掉分隔符
    /// 后退化为单字符 token：含空格的 2 字查询在 2-gram 索引恒查不到
    /// （纯文本文档的 CJK 对不含该 token），"a-" 类查询退化为裸 "a" 全表
    /// 过匹配。写入侧与查询侧共用本函数（SQL bigrams() 注册 + MATCH 构造），
    /// 一次修正两侧同源一致。
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
            let a = chars[index], b = chars[index + 1]
            guard (a.isLetter || a.isNumber), (b.isLetter || b.isNumber) else { continue }
            result.append(String(a) + String(b))
        }
        return result
    }

    /// 高亮片段：命中词在片段中的首现位置（snippet 生成由 FTS snippet 函数承担，
    /// Domain 侧提供「敏感媒体只命中元数据」规则）
    public static func isSensitiveDoc(_ docKind: String) -> Bool {
        docKind == "sensitive_photo" || docKind == "sensitive_media"
    }

    /// 片段高亮标记（单一事实源）：FTS `snippet()` 与手动高亮共用；UI 一律经
    /// `highlightSegments` 拆段渲染，AI 摘录经 `stripHighlight` 去标记——
    /// 全仓审查 2026-09-18（F-A8-01/F-D1-02）：此前 `<b>` 字面渗出到 `Text(snippet)`
    /// 与 AI 七段卡摘录。
    public static let highlightOpen = "<b>"
    public static let highlightClose = "</b>"

    /// 片段拆段结果：UI 按 `highlighted` 加粗，不再让标记字面渗出。
    public struct SnippetSegment: Sendable, Equatable {
        public let text: String
        public let highlighted: Bool
        public init(text: String, highlighted: Bool) {
            self.text = text
            self.highlighted = highlighted
        }
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
        return lead + text[lower..<range.lowerBound] + highlightOpen + query + highlightClose
            + text[range.upperBound..<upper] + trail
    }

    /// 把带标记的片段拆成有序段：未闭合/嵌套异常的标记按纯文本处理，绝不吞字。
    public static func highlightSegments(_ snippet: String) -> [SnippetSegment] {
        var segments: [SnippetSegment] = []
        var rest = Substring(snippet)
        while let open = rest.range(of: highlightOpen) {
            let before = rest[rest.startIndex..<open.lowerBound]
            if !before.isEmpty { segments.append(SnippetSegment(text: String(before), highlighted: false)) }
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: highlightClose) else {
                // 未闭合：余下全部按纯文本
                if !afterOpen.isEmpty { segments.append(SnippetSegment(text: String(afterOpen), highlighted: false)) }
                return segments
            }
            let hit = afterOpen[afterOpen.startIndex..<close.lowerBound]
            if !hit.isEmpty { segments.append(SnippetSegment(text: String(hit), highlighted: true)) }
            rest = afterOpen[close.upperBound...]
        }
        if !rest.isEmpty { segments.append(SnippetSegment(text: String(rest), highlighted: false)) }
        return segments
    }

    /// 去标记纯文本（AI 摘录/无障碍朗读/导出用）。
    public static func stripHighlight(_ snippet: String) -> String {
        highlightSegments(snippet).map(\.text).joined()
    }
}
