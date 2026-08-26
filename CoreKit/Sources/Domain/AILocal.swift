import Foundation

/// F12 本地检索式 AI（ADR-003 / §5.5）：检索 + 模板组装，无生成式文本——
/// 结构性满足「不虚构」。七段结构与引用完整性由类型保证。
public struct AIQuery: Sendable, Equatable {
    public var text: String
    public var member: UUID?
    public init(text: String, member: UUID? = nil) { self.text = text; self.member = member }
}

public struct DataAccessScope: Sendable, Equatable {
    public var patientIds: Set<UUID>
    public init(patientIds: Set<UUID>) { self.patientIds = patientIds }
}

/// 引用实体（只能由检索命中构造——不存在「无引用的回答」分支）
public struct EntityReference: Sendable, Equatable {
    public var kind: String
    public var refID: UUID
    public var title: String
    public var snippet: String
    public init(kind: String, refID: UUID, title: String, snippet: String) {
        self.kind = kind; self.refID = refID; self.title = title; self.snippet = snippet
    }
}

/// 七段结构（FR12.5）
public struct AIAnswer: Sendable, Equatable {
    public enum Body: Sendable, Equatable {
        case composed(SevenPart)
        case refused(Refusal)
        case emergencyCard
    }
    public struct SevenPart: Sendable, Equatable {
        public var conclusion: String        // 结论（仅复述检索事实）
        public var citations: [EntityReference]
        public var excerpts: [String]        // 原文摘录
        public var terminology: [String]     // B 级术语词典通俗解释
        public var scopeNote: String         // 只读了哪些资料（最小必要访问）
        public var disclaimer: String        // 固定免责
        public var gradeBadge: String        // E 级标识（AI 解释）
    }
    public struct Refusal: Sendable, Equatable {
        public enum Reason: String, Sendable, Equatable {
            case insufficientData, highRiskTopic
        }
        public var reason: Reason
        public var detail: String
    }
    public var body: Body

    public var citations: [EntityReference] {
        if case .composed(let p) = body { return p.citations }
        return []
    }
}

/// P0 内置术语词典（FR12.4：医学术语→通俗解释，无阈值无诊断含义；
/// 与 GuidelineSource（P1 阈值信源库）严格分离）
public struct TerminologyStore: Sendable {
    public static let shared = TerminologyStore(entries: [
        "血压": "血液对血管壁的压力，通常记录收缩压/舒张压两个数字",
        "血糖": "血液中的葡萄糖浓度，常以 mmol/L 表示",
        "收缩压": "心脏收缩时动脉内的最高压力",
        "舒张压": "心脏舒张时动脉内的最低压力",
        "空腹血糖": "至少 8 小时未进食后测得的血糖值",
        "阿莫西林": "青霉素类抗生素，用于细菌感染（具体用法以处方为准）",
    ])
    private let entries: [String: String]
    public init(entries: [String: String]) { self.entries = entries }
    public func explain(_ term: String) -> String? { entries[term] }
    public func terms(in text: String) -> [String] {
        entries.keys.filter { text.contains($0) }
    }
}

/// 紧急关键词规则（BR-012：疑似紧急 → 急救卡，绝不继续普通问答）
public enum EmergencyKeywordRules {
    static let keywords = ["胸痛", "胸口疼", "胸闷得厉害", "呼吸困难", "喘不上气",
                       "意识不清", "大出血", "抽搐", "休克", "窒息", "喉头水肿", "喘不过气"]
    public static func match(_ text: String) -> Bool {
        keywords.contains { text.contains($0) }
    }
}

/// 高风险话题规则（BR-006：调药/停药/剂量更改 → 拒绝）。
/// 评审修正：词表穷举子串可被规格验收句绕过（「帮我停掉阿司匹林」不命中
/// 「停药」）——补动词变体 + 剂量数字正则（「XXmg/片/粒/次」）。
public enum HighRiskTopicRules {
    static let keywords = [
        "停药", "停掉", "停用", "别再吃", "不吃了", "不想吃", "想停药", "停用吗", "需要停药吗",
        "加量", "减量", "换药", "加倍", "调整剂量", "自行停用",
        "增加剂量", "减少剂量", "多吃", "少吃",
    ]
    /// 剂量更改句式正则：动词(吃/服/加到/减到/改为) + 数字 + 单位
    static let doseChangePatterns = [
        #"吃\s*[0-9一二三四五六七八九十两]+\s*(mg|片|粒|颗|次|倍)"#,
        #"服\s*[0-9一二三四五六七八九十两]+\s*(mg|片|粒|颗|次|倍)"#,
        #"(加到|减到|改为|降到|改成)\s*[0-9一二三四五六七八九十两]+\s*(mg|片|粒|颗)"#,
        #"[0-9]+\s*(mg|片|粒)\s*(每次|每日)"#,
    ]
    public static func match(_ text: String) -> Bool {
        if keywords.contains(where: { text.contains($0) }) { return true }
        return doseChangePatterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }
}

/// 全文检索端口（Infrastructure FTS 实现注入）
public protocol FullTextSearch: Sendable {
    func search(_ text: String, scope: DataAccessScope, limit: Int) async throws -> [EntityReference]
}

/// P0 本地实现（§5.5 骨架）
public struct LocalRetrievalProvider: AIProvider {
    let search: any FullTextSearch
    let terminology: TerminologyStore

    public init(search: any FullTextSearch, terminology: TerminologyStore = .shared) {
        self.search = search
        self.terminology = terminology
    }

    public func answer(_ q: AIQuery, scope: DataAccessScope) async throws -> AIAnswer {
        // BR-012 优先：疑似紧急 → 急救卡
        if EmergencyKeywordRules.match(q.text) {
            return AIAnswer(body: .emergencyCard)
        }
        // BR-006：调药/停药类 → 安全拒识
        if HighRiskTopicRules.match(q.text) {
            return AIAnswer(body: .refused(.init(
                reason: .highRiskTopic,
                detail: "调整或停用药物必须由医生决定；请带着处方咨询医生或药师。")))
        }
        let hits = try await search.search(q.text, scope: scope, limit: 12)
        guard !hits.isEmpty else {
            return AIAnswer(body: .refused(.init(
                reason: .insufficientData,
                detail: "你的资料里暂时没有与这个问题相关的内容。可以补充病历、报告或自测记录后再问。")))
        }
        return AIAnswer(body: .composed(compose(hits, question: q.text)))
    }

    /// 七段组装（FR12.5）：结论只复述检索事实；术语解释来自 B 级词典；
    /// 固定免责句；E 级徽章标识 AI 解释。
    func compose(_ hits: [EntityReference], question: String) -> AIAnswer.SevenPart {
        let excerpts = hits.prefix(3).map(\.snippet)
        let terms = terminology.terms(in: question)
            .compactMap { term in terminology.explain(term).map { "\(term)：\($0)" } }
        return AIAnswer.SevenPart(
            conclusion: "找到 \(hits.count) 条与你的问题相关的资料。",
            citations: hits,
            excerpts: excerpts,
            terminology: terms,
            scopeNote: "本次回答只读取了 \(hits.count) 条与你相关的资料。",
            disclaimer: "以上内容来自你的资料与通用术语解释，不能替代医生诊断或用药指导。",
            gradeBadge: "E")
    }
}

public protocol AIProvider: Sendable {
    func answer(_ q: AIQuery, scope: DataAccessScope) async throws -> AIAnswer
}

/// 审计装饰器（§5.5/§5.6）：记录 scope.patientIds 哈希而非明文
public struct AuditedAIProvider: AIProvider {
    let inner: any AIProvider
    let audit: @Sendable (String) async -> Void   // 注入审计写入口（哈希后落库）
    public init(inner: any AIProvider, audit: @escaping @Sendable (String) async -> Void) {
        self.inner = inner
        self.audit = audit
    }
    public func answer(_ q: AIQuery, scope: DataAccessScope) async throws -> AIAnswer {
        let ids = scope.patientIds.map(\.uuidString).sorted().joined(separator: ",")
        await audit(ids)   // 调用方负责哈希；此处只传事实
        return try await inner.answer(q, scope: scope)
    }
}
