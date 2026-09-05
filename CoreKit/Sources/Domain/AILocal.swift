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
    /// BR-007/008：敏感资料命中标记——搜索/AI 引用呈现必须以此决定锁定态，
    /// 不得因搜索命中自动解锁图片（FR12.1 边界）
    public var isSensitive: Bool
    public init(kind: String, refID: UUID, title: String, snippet: String,
                isSensitive: Bool = false) {
        self.kind = kind; self.refID = refID; self.title = title
        self.snippet = snippet; self.isSensitive = isSensitive
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
        public var conclusion: String        // ①结论（仅复述检索事实）
        public var citations: [EntityReference]  // ②引用（类型保证非空）
        public var excerpts: [String]        // ③原文摘录
        public var terminology: [String]     // ④B 级术语词典通俗解释
        public var sources: [String]         // ⑤来源说明（评审补：每条引用来自哪类资料）
        public var uncertainties: [String]   // ⑥不确定与缺失（评审补：资料中查不到的部分）
        public var questionsForDoctor: [String]  // ⑦建议向医生提问（评审补）
        public var scopeNote: String         // 只读了哪些资料（最小必要访问）
        public var disclaimer: String        // 固定免责
        public var gradeBadge: String        // E 级标识（AI 解释）
    }
    public struct Refusal: Sendable, Equatable {
        public enum Reason: String, Sendable, Equatable {
            case insufficientData, highRiskTopic
        }
        public enum Action: String, Sendable, Equatable {
            case addRecords        // 去补充资料
            case consultDoctor     // 咨询医生/药师
        }
        public var reason: Reason
        public var detail: String
        public var actions: [Action]
        public init(reason: Reason, detail: String, actions: [Action]) {
            self.reason = reason
            self.detail = detail
            self.actions = actions
        }
    }
    public var body: Body
    public init(body: Body) { self.body = body }

    public var citations: [EntityReference] {
        if case .composed(let p) = body { return p.citations }
        return []
    }
}

// MARK: - 红线答案工厂（同一情形只有一种文案）

public extension AIAnswer {
    /// BR-012 急救卡
    static var emergency: AIAnswer { AIAnswer(body: .emergencyCard) }

    /// BR-006 资料不足拒识。Provider 与纵深防御装饰器共用同一工厂，避免同一情形
    /// 因「哪一层先判定」而产生两种 Refusal。
    ///
    /// 注意 `detail` 是**诊断/测试用默认值，不上屏**：Domain 是纯 Swift 层，取不到
    /// .strings，硬编码简体一旦上屏就等于 zh-Hant/en 用户看到简体。呈现文案的唯一
    /// 出口是 App 层按 `reason` 取 L10n（见 AssistantStore.refusalDetail）。
    static var insufficientData: AIAnswer {
        AIAnswer(body: .refused(Refusal(
            reason: .insufficientData,
            detail: "你的资料里暂时没有与这个问题相关的内容。可以补充病历、报告或自测记录后再问。",
            actions: [.addRecords, .consultDoctor])))
    }

    /// BR-006 高风险话题拒识（调药/停药类）。同上：`detail` 不上屏，呈现走 L10n。
    static var highRiskTopic: AIAnswer {
        AIAnswer(body: .refused(Refusal(
            reason: .highRiskTopic,
            detail: "调整或停用药物必须由医生决定；请带着处方咨询医生或药师。",
            actions: [.consultDoctor])))
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
            return .emergency
        }
        // BR-006：调药/停药类 → 安全拒识（装配层的 SafeAIProvider 亦独立拦一次；
        // 此处保留使未加装饰器直接使用本 Provider 时红线依然成立）
        if HighRiskTopicRules.match(q.text) {
            return .highRiskTopic
        }
        let hits = try await search.search(q.text, scope: scope, limit: 12)
        guard !hits.isEmpty else {
            return .insufficientData
        }
        // BR-006 执法：负清单命中 → 安全降级（拦截优于展示错误文案）
        guard let composed = compose(hits, question: q.text) else {
            return .insufficientData
        }
        return AIAnswer(body: .composed(composed))
    }

    /// 七段组装（FR12.5）：结论只复述检索事实；术语解释来自 B 级词典；
    /// 固定免责句；E 级徽章标识 AI 解释。
    /// 审查修复（BR-006 一票否决执法）：组装完成后对**生成文案**跑
    /// WordingBlacklist——全仓此前只有定义与测试、无任何生产调用点。
    /// 命中即返回 nil（调用侧安全降级 .insufficientData），拦截优于展示。
    func compose(_ hits: [EntityReference], question: String) -> AIAnswer.SevenPart? {
        let excerpts = hits.prefix(3).map(\.snippet)
        let terms = terminology.terms(in: question)
            .compactMap { term in terminology.explain(term).map { "\(term)：\($0)" } }
        let card = AIAnswer.SevenPart(
            conclusion: "找到 \(hits.count) 条与你的问题相关的资料。",
            citations: hits,
            excerpts: excerpts,
            terminology: terms,
            sources: hits.map { "\($0.kind)（\($0.title)）" },
            uncertainties: ["你的资料中可能还有纸质资料未收录；本回答只基于已归档内容。"],
            questionsForDoctor: ["就诊时可以带着这些资料，请医生确认与你的情况是否一致。"],
            scopeNote: "本次回答只读取了 \(hits.count) 条与你相关的资料。",
            disclaimer: "以上内容来自你的资料与通用术语解释，不能替代医生诊断或用药指导。",
            gradeBadge: "E")
        let generated = [card.conclusion, card.uncertainties.joined(),
                         card.questionsForDoctor.joined(), card.scopeNote, card.disclaimer]
        for text in generated where WordingBlacklist.violation(in: text) != nil {
            return nil   // 负清单命中：整卡安全降级，不展示违规文案
        }
        return card
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

/// 红线纵深防御装饰器（BR-012 / BR-006）。
///
/// 为什么在 Domain 而不是在 Store：BR 规则是 Domain 纯逻辑（架构规则 4），
/// 且装饰器对**任何** AIProvider 生效——P1 云端实现（D1/D3）无需重复实现，
/// 未来第二个 `provider.answer` 调用方也不可能绕过。放在某个 Store 里，
/// 两者都不成立。
///
/// 三条不变量：
/// ① 紧急关键词命中 → 必出急救卡，即便内层 Provider 误分类；
/// ② 高风险话题（措辞负清单：调药/停药）→ 必拒识。红线是「一票否决」，
///    因此不能只长在 LocalRetrievalProvider 里：任何 Provider（P1 云端 D1/D3）
///    都可能返回带引用的剂量结论，装饰器必须在装配层统一拦住。
/// ③ 组合答案 citations 为空 → 拒识。citations 是唯一类型化出处，
///    excerpts 是无溯源纯文本，故只认 citations。
///
/// ①② 均**前置短路**：两者的答案都是固定内容，不读任何资料即可给出。提前返回既省掉
/// 一次 FTS 检索/云端往返，也避免为用不到资料的提问去访问病历（最小必要访问）；
/// 同时让「错误路径漏红线」由结构排除——内层根本不会被调用。
public struct SafeAIProvider: AIProvider {
    let inner: any AIProvider
    public init(inner: any AIProvider) { self.inner = inner }

    public func answer(_ q: AIQuery, scope: DataAccessScope) async throws -> AIAnswer {
        if EmergencyKeywordRules.match(q.text) { return .emergency }        // ①
        if HighRiskTopicRules.match(q.text) { return .highRiskTopic }       // ②
        let answer = try await inner.answer(q, scope: scope)
        if case .composed(let p) = answer.body, p.citations.isEmpty {
            return .insufficientData                                       // ③
        }
        return answer
    }
}
