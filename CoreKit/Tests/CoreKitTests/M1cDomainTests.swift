import Foundation
import Testing
@testable import Domain

/// M1c P0 收口 · Domain 层验收用例（dev-pm §3.2.3 退出准则的 U 半场）
@Suite("M1c · 时间轴投影与游标分页（§5.30/F11）")
struct TimelineServiceTests {
    private func entry(_ kind: TimelineEntryKind, _ t: TimeInterval, _ id: String) -> TimelineEntry {
        TimelineEntry(kind: kind, date: Date(timeIntervalSince1970: t), title: "t-\(id)",
                      summary: nil, refID: UUID(uuidString: String(repeating: id, count: 32)) ?? UUID(),
                      memberId: UUID())
    }

    @Test func 稳定排序与游标翻页() {
        let m = UUID()
        var entries = (0..<25).map { i in
            TimelineEntry(kind: .observation, date: Date(timeIntervalSince1970: TimeInterval(1000 - i)),
                          title: "e\(i)", summary: nil, refID: UUID(), memberId: m)
        }
        let sorted = TimelineProjectionRules.sort(entries)
        // 第一页 10 条
        let p1 = TimelineProjectionRules.page(sorted, limit: 10)
        #expect(p1.entries.count == 10)
        #expect(p1.nextCursor != nil)
        // 游标翻页：第二页不重不漏
        let rest = TimelineProjectionRules.after(sorted, cursor: p1.nextCursor!)
        let p2 = TimelineProjectionRules.page(rest, limit: 10)
        #expect(p2.entries.count == 10)
        let p3 = TimelineProjectionRules.page(TimelineProjectionRules.after(rest, cursor: p2.nextCursor!), limit: 10)
        #expect(p3.entries.count == 5)
        #expect(p3.nextCursor == nil)
        // 不重不漏
        var all = p1.entries + p2.entries + p3.entries
        #expect(Set(all.map(\.title)).count == 25)
        #expect(all == sorted)   // 顺序一致
        _ = entries.removeAll()
    }

    @Test func 成员隔离() {
        let a = UUID()
        let b = UUID()
        let entries = [
            TimelineEntry(kind: .observation, date: Date(), title: "A", summary: nil, refID: UUID(), memberId: a),
            TimelineEntry(kind: .observation, date: Date(), title: "B", summary: nil, refID: UUID(), memberId: b),
        ]
        #expect(TimelineProjectionRules.scoped(entries, member: a).map(\.title) == ["A"])
    }
}

@Suite("M1c · 搜索路由（§4.3 V3.24/F12）")
struct SearchRulesTests {
    @Test func 查询长度路由() {
        #expect(SearchRules.route("血糖") == .bigram)          // 2 字
        #expect(SearchRules.route("空腹血糖") == .trigram)     // ≥3 字
        #expect(SearchRules.route("糖") == .like)              // 1 字
        #expect(SearchRules.route("  ") == .invalid)
    }

    @Test func 二克切分() {
        #expect(SearchRules.bigrams("空腹血糖") == ["空腹", "腹血", "血糖"])
    }

    @Test func 敏感媒体只命中元数据() {
        #expect(SearchRules.isSensitiveDoc("sensitive_photo"))
        #expect(!SearchRules.isSensitiveDoc("prescription"))
    }
}

@Suite("M1c · 首页八卡聚合（§5.33/F2）")
struct TodayStoreTests {
    @Test func 成员隔离与待办合并排序() {
        let me = UUID()
        let other = UUID()
        let todos = [
            TodoItem(kind: .doseSlot, at: Date(timeIntervalSince1970: 300), title: "服药", memberId: me),
            TodoItem(kind: .appointment, at: Date(timeIntervalSince1970: 100), title: "复诊", memberId: me),
            TodoItem(kind: .doseSlot, at: Date(timeIntervalSince1970: 200), title: "他人", memberId: other),
        ]
        let snap = TodayAggregator.snapshot(member: me, todos: todos, pendingOCRCount: 2,
                                            expiring: [], refills: [], alerts: [], observations: [])
        #expect(snap.todoItems.map(\.title) == ["复诊", "服药"])
        #expect(snap.pendingOCRCount == 2)
    }

    @Test func 仅L1以上预警入首页() {
        let me = UUID()
        let alerts = [
            AlertRef(severity: "L0", title: "正常", memberId: me),
            AlertRef(severity: "L2", title: "血压偏高", memberId: me),
        ]
        let snap = TodayAggregator.snapshot(member: me, todos: [], pendingOCRCount: 0,
                                            expiring: [], refills: [], alerts: alerts, observations: [])
        #expect(snap.alertSummary.map(\.title) == ["血压偏高"])
    }

    @Test func 近期观察取前三条() {
        let me = UUID()
        let obs = (0..<5).map { i in
            ObsRef(id: UUID(), kind: "skin", occurredAt: Date(timeIntervalSince1970: TimeInterval(100 + i)), memberId: me)
        }
        let snap = TodayAggregator.snapshot(member: me, todos: [], pendingOCRCount: 0,
                                            expiring: [], refills: [], alerts: [], observations: obs)
        #expect(snap.recentObservations.count == 3)
        #expect(snap.recentObservations.first!.occurredAt == Date(timeIntervalSince1970: 104))
    }
}

@Suite("M1c · CSV 导出（FR13.3 RFC4180）")
struct CSVWriterTests {
    @Test func 引号逗号换行转义() {
        #expect(CSVWriter.escape("正常") == "正常")
        #expect(CSVWriter.escape("含,逗号") == "\"含,逗号\"")
        #expect(CSVWriter.escape("含\"引号") == "\"含\"\"引号\"")
        #expect(CSVWriter.escape("含\n换行") == "\"含\n换行\"")
    }

    @Test func 文档与BOM() {
        let doc = CSVWriter.document(headers: ["药名", "剂量"], rows: [["阿莫西林", "0.25g"]])
        #expect(doc.hasPrefix("药名,剂量\r\n"))
        #expect(doc.hasSuffix("\r\n"))
        let data = CSVWriter.encode(headers: ["x"], rows: [["y"]])
        #expect(data.prefix(3) == CSVWriter.bom)
    }

    @Test func 分包() {
        let rows = (0..<25).map { ["r\($0)"] }
        let parts = CSVWriter.split(baseName: "export", headers: ["h"], rows: rows, maxRows: 10)
        #expect(parts.count == 3)
        #expect(parts[0].name == "export-part1.csv")
        #expect(parts.map(\.rows.count) == [10, 10, 5])
    }
}

// binds: SU-M1c-AI — TC-M1c-02/03（BR-006/012 一票否决）
@Suite("SU-M1c-AI · 本地检索式 AI（§5.5/BR-006/BR-012）")
struct AILocalTests {
    actor FakeSearch: FullTextSearch {
        var hits: [EntityReference] = []
        func set(_ h: [EntityReference]) { hits = h }
        func search(_ text: String, scope: DataAccessScope, limit: Int) async throws -> [EntityReference] {
            Array(hits.prefix(limit))
        }
    }

    @Test func 紧急关键词返回急救卡() async throws {
        let search = FakeSearch()
        let provider = LocalRetrievalProvider(search: search)
        let answer = try await provider.answer(AIQuery(text: "我父亲胸痛得厉害"), scope: .init(patientIds: []))
        #expect(answer.body == .emergencyCard)
    }

    /// 规格验收句参数化（评审修正：原词表不命中「帮我停掉阿司匹林」）
    @Test(arguments: ["我可以自行停药吗", "帮我停掉阿司匹林", "这个药我不想吃了",
                      "每天吃 2 片改成 3 片", "加到 10mg 可以吗", "血压好了是不是可以停用降压药"])
    func 高风险话题变体拒识(_ phrase: String) async throws {
        let search = FakeSearch()
        await search.set([EntityReference(kind: "prescription", refID: UUID(), title: "处方", snippet: "阿莫西林 0.25g")])
        let provider = LocalRetrievalProvider(search: search)
        let answer = try await provider.answer(AIQuery(text: phrase), scope: .init(patientIds: []))
        guard case .refused(let r) = answer.body else {
            Issue.record("高风险短语必须拒识: \(phrase)")
            return
        }
        #expect(r.reason == .highRiskTopic)
    }

    @Test func 调药停药高风险拒识() async throws {
        let search = FakeSearch()
        await search.set([EntityReference(kind: "prescription", refID: UUID(), title: "处方", snippet: "阿莫西林 0.25g")])
        let provider = LocalRetrievalProvider(search: search)
        let answer = try await provider.answer(AIQuery(text: "我可以自行停药吗"), scope: .init(patientIds: []))
        guard case .refused(let r) = answer.body else {
            Issue.record("高风险话题必须拒识")
            return
        }
        #expect(r.reason == .highRiskTopic)
    }

    @Test func 无命中资料不足拒识() async throws {
        let search = FakeSearch()
        let provider = LocalRetrievalProvider(search: search)
        let answer = try await provider.answer(AIQuery(text: "我的血压怎么样"), scope: .init(patientIds: []))
        guard case .refused(let r) = answer.body else {
            Issue.record("无命中必须 insufficientData 拒识")
            return
        }
        #expect(r.reason == .insufficientData)
    }

    @Test func 七段结构与引用完整性() async throws {
        let search = FakeSearch()
        let ref = EntityReference(kind: "document_file", refID: UUID(), title: "血压记录", snippet: "收缩压 132 mmHg")
        await search.set([ref])
        let provider = LocalRetrievalProvider(search: search)
        let answer = try await provider.answer(AIQuery(text: "我的血压"), scope: .init(patientIds: []))
        guard case .composed(let p) = answer.body else {
            Issue.record("有命中必须组装七段")
            return
        }
        #expect(p.citations.count == 1)
        #expect(p.excerpts == ["收缩压 132 mmHg"])
        #expect(p.gradeBadge == "E")
        // V3.70：模板句移 App 层 L10n 渲染——Domain 侧断言类型化字段
        // （免责/scope 句式随 App 层模板测试过 BR-006 负清单）
        #expect(p.citationCount == 1)
        #expect(!p.terminologyPairs.isEmpty, "问题含「血压」应命中 B 级术语词典")
        #expect(p.sources.count == 1)
        #expect(p.sources[0].title == "血压记录")
    }

    @Test func 术语词典独立于信源库() {
        #expect(TerminologyStore.shared.explain("收缩压") != nil)
        #expect(TerminologyStore.shared.explain("不存在的术语") == nil)
    }
}

// binds: SU-M1c-AI — TC-M1c-02/03（红线纵深防御：装饰器对任何 Provider 生效）
@Suite("SU-M1c-AI · SafeAIProvider 纵深防御（BR-006/BR-012）")
struct SafeAIProviderTests {
    /// 故意「坏」的 Provider：模拟误分类的 P1 云端实现
    struct MisbehavingProvider: AIProvider {
        var stub: AIAnswer?
        var error: Error?
        func answer(_ q: AIQuery, scope: DataAccessScope) async throws -> AIAnswer {
            if let error { throw error }
            return stub ?? .insufficientData
        }
    }

    struct Boom: Error {}

    /// BR-012：内层把紧急提问当普通问答返回，装饰器必须改写为急救卡
    @Test func 内层误分类紧急提问时强制急救卡() async throws {
        let inner = MisbehavingProvider(stub: AIAnswer(body: .composed(.init(
            citationCount: 1, terminologyPairs: [],
            citations: [EntityReference(kind: "x", refID: UUID(), title: "t", snippet: "s")],
            excerpts: [], sources: [], gradeBadge: "E"))))
        let answer = try await SafeAIProvider(inner: inner)
            .answer(AIQuery(text: "我父亲胸痛得厉害"), scope: .init(patientIds: []))
        #expect(answer.body == .emergencyCard)
    }

    /// BR-012 错误路径：provider 抛错也不得漏掉急救卡（降级/云端故障）
    @Test func 内层抛错时紧急提问仍出急救卡() async throws {
        let answer = try await SafeAIProvider(inner: MisbehavingProvider(error: Boom()))
            .answer(AIQuery(text: "胸痛"), scope: .init(patientIds: []))
        #expect(answer.body == .emergencyCard)
    }

    /// 非紧急提问的错误必须继续抛出——不能被静默吞成假答案
    @Test func 非紧急提问的错误继续抛出() async {
        await #expect(throws: Boom.self) {
            _ = try await SafeAIProvider(inner: MisbehavingProvider(error: Boom()))
                .answer(AIQuery(text: "我的血压怎么样"), scope: .init(patientIds: []))
        }
    }

    /// BR-006：零引用的确定性结论一律退回拒识（excerpts 非空也不例外——
    /// excerpts 是无溯源纯文本，citations 才是唯一类型化出处）
    @Test func 零引用的组合答案退回拒识() async throws {
        let inner = MisbehavingProvider(stub: AIAnswer(body: .composed(.init(
            citationCount: 0, terminologyPairs: [],
            citations: [],
            excerpts: ["看起来可以加量"], sources: [], gradeBadge: "E"))))
        let answer = try await SafeAIProvider(inner: inner)
            .answer(AIQuery(text: "我的血压怎么样"), scope: .init(patientIds: []))
        guard case .refused(let r) = answer.body else {
            Issue.record("零引用组合答案必须拒识")
            return
        }
        #expect(r.reason == .insufficientData)
    }

    /// 有引用的正常答案必须原样透传（装饰器不得改写合法结果）
    @Test func 合法答案原样透传() async throws {
        let ref = EntityReference(kind: "document_file", refID: UUID(), title: "血压", snippet: "132")
        let stub = AIAnswer(body: .composed(.init(
            citationCount: 1, terminologyPairs: [],
            citations: [ref], excerpts: ["132"],
            sources: [], gradeBadge: "E")))
        let answer = try await SafeAIProvider(inner: MisbehavingProvider(stub: stub))
            .answer(AIQuery(text: "我的血压怎么样"), scope: .init(patientIds: []))
        #expect(answer == stub)
    }

    /// BR-006 一票否决：任何 Provider 返回的「带引用剂量结论」都必须被装饰器拦成拒识。
    /// 这是 P1 云端（D1/D3）接入后最危险的路径——引用非空会让 ③ 的兜底失效。
    @Test(arguments: ["把阿莫西林加到 500mg 每天", "我可以自行停药吗", "这个药我不想吃了"])
    func 高风险话题即便带引用也拒识(_ phrase: String) async throws {
        let ref = EntityReference(kind: "prescription", refID: UUID(), title: "处方", snippet: "阿莫西林 0.25g")
        let inner = MisbehavingProvider(stub: AIAnswer(body: .composed(.init(
            citationCount: 1, terminologyPairs: [],
            citations: [ref], excerpts: ["阿莫西林 0.25g"],
            sources: [], gradeBadge: "E"))))
        let answer = try await SafeAIProvider(inner: inner)
            .answer(AIQuery(text: phrase), scope: .init(patientIds: []))
        guard case .refused(let r) = answer.body else {
            Issue.record("高风险话题必须拒识（即便内层给了引用）: \(phrase)")
            return
        }
        #expect(r.reason == .highRiskTopic)
    }

    /// 同一情形只有一种文案：Provider 与装饰器共用 .insufficientData 工厂
    @Test func 资料不足文案单一出口() async throws {
        let viaDecorator = try await SafeAIProvider(inner: MisbehavingProvider())
            .answer(AIQuery(text: "我的血压怎么样"), scope: .init(patientIds: []))
        #expect(viaDecorator == AIAnswer.insufficientData)
    }
}

// §5.5/§5.6 审计装饰器：scope 以**排序后的哈希前形态**上报，答案原样透传。
// 此前零测试（评审补）：审计是隐私合规证据链的一环，落库内容错了没有用例会红。
@Suite("SU-M1c-AI · 审计装饰器（§5.5/§5.6）")
struct AuditedAIProviderTests {
    /// 审计写入侧替身（锁保护；audit 闭包可能来自任意并发域）
    final class AuditSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        func record(_ s: String) { lock.lock(); defer { lock.unlock() }; _calls.append(s) }
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    }

    @Test func 审计收到排序成员ID且答案透传() async throws {
        let sink = AuditSink()
        let decorated = AuditedAIProvider(
            inner: MisbehavingProviderStub(answer: .insufficientData)) { ids in
                sink.record(ids)
            }
        let a = UUID(), b = UUID()
        let answer = try await decorated.answer(
            AIQuery(text: "我的血压怎么样"),
            scope: DataAccessScope(patientIds: [b, a]))     // 乱序注入
        #expect(answer == .insufficientData)
        #expect(sink.calls.count == 1, "每次提问必须产生一条审计记录")
        let expected = [a, b].map(\.uuidString).sorted().joined(separator: ",")
        #expect(sink.calls[0] == expected, "成员 ID 必须排序后上报（哈希前形态）")
    }

    /// 内层抛错时审计仍必须已落（审计先于应答执行——失败请求同样留痕）
    @Test func 内层抛错审计仍执行() async {
        struct Boom: Error {}
        let sink = AuditSink()
        let decorated = AuditedAIProvider(
            inner: MisbehavingProviderStub(error: Boom())) { ids in
                sink.record(ids)
            }
        await #expect(throws: Boom.self) {
            _ = try await decorated.answer(
                AIQuery(text: "我的血压怎么样"),
                scope: DataAccessScope(patientIds: []))
        }
        #expect(sink.calls.count == 1, "失败请求同样必须留痕（审计先于应答）")
    }
}

/// 供审计装饰器测试的轻量 Provider 桩（避免与 SafeAIProviderTests 的桩互相依赖）
private struct MisbehavingProviderStub: AIProvider {
    var failure: Error?
    var stub: AIAnswer
    init(answer: AIAnswer? = nil, error: Error? = nil) {
        self.failure = error
        self.stub = answer ?? .insufficientData
    }
    func answer(_ q: AIQuery, scope: DataAccessScope) async throws -> AIAnswer {
        if let failure { throw failure }
        return stub
    }
}

@Suite("M1c · 偏好设置（§5.28/FR14.7）")
struct AppSettingsTests {
    @Test func 全键默认值齐备() {
        for key in AppSettingKey.allCases {
            #expect(!key.defaultValue.isEmpty || key == .defaultMemberId || key == .dataRetentionDays,
                    "键 \(key.rawValue) 必须声明默认值（新增键禁止裸奔）")
        }
    }

    @Test func 追溯语义仅影响新建() {
        #expect(!SettingsRules.appliesToExisting(.defaultMemberId))
        #expect(!SettingsRules.appliesToExisting(.snoozeMinutes))
        #expect(SettingsRules.appliesToExisting(.careModeEnable))
    }

    @Test func 主题键默认值_跟随系统且高对比关闭() {
        // FR14.4（tech-spec §5.28.1）：appearance 默认 system（nil = 跟随系统）、
        // highContrastEnabled 默认 false。落在 App 层的 AppTheme/AppearanceRules
        // 映射与叠加规则由 App 层 XCTest（SU-M1c-FR14）覆盖。
        #expect(AppSettingKey.appearance.defaultValue == "system")
        #expect(AppSettingKey.highContrastEnabled.defaultValue == "false")
        #expect(AppSettingKey.allCases.contains(.appearance))
        #expect(AppSettingKey.allCases.contains(.highContrastEnabled))
    }
}

// binds: SU-M1c-SEC — TC-M1c-01（敏感越权=0 一票否决）
@Suite("SU-M1c-SEC · 观察聚合与就诊展示（§5.36/F8）")
struct ObservationServiceTests {
    @Test func 同组聚合与成员隔离() {
        let me = UUID()
        let other = UUID()
        let g = UUID()
        let events = [
            ObservationEvent(id: UUID(), groupId: g, kind: .skin, occurredAt: Date(timeIntervalSince1970: 100),
                             description: "红疹", selfMark: "worsened", memberId: me),
            ObservationEvent(id: UUID(), groupId: g, kind: .skin, occurredAt: Date(timeIntervalSince1970: 200),
                             description: "消退", selfMark: "improved", memberId: me),
            ObservationEvent(id: UUID(), kind: .skin, occurredAt: Date(timeIntervalSince1970: 300),
                             description: "他人", selfMark: nil, memberId: other),
        ]
        let groups = ObservationGroupService.groups(events, member: me)
        #expect(groups.count == 1)
        #expect(groups[0].occurrences.count == 2)
        #expect(groups[0].selfMark == "improved")   // 最新自评
    }

    @Test func 展示会话超时自动重锁与scope过滤() {
        let me = UUID()
        let event = ObservationEvent(id: UUID(), kind: .skin, occurredAt: Date(),
                                     description: "红疹", selfMark: nil, memberId: me)
        let session = DoctorShowcaseSession(patientId: me, unlockedAt: Date(timeIntervalSince1970: 0),
                                            timeoutSeconds: 300, scopeKind: .skin)
        #expect(!session.isActive(at: Date(timeIntervalSince1970: 400)))   // 超时重锁
        #expect(DoctorShowcaseRules.visibleEvents([event], session: session,
                                                  now: Date(timeIntervalSince1970: 400)).isEmpty)
        let activeSession = DoctorShowcaseSession(patientId: me, unlockedAt: Date(timeIntervalSince1970: 0),
                                                  timeoutSeconds: 300, scopeKind: .urine)
        #expect(DoctorShowcaseRules.visibleEvents([event], session: activeSession,
                                                  now: Date(timeIntervalSince1970: 100)).isEmpty)  // scope 过滤
    }
}

// binds: SU-M1c-IAP — FR3.7 成员配额判定（comercial §3 memberQuotaReached 的 Domain 半场）
@Suite("SU-M1c-IAP · 成员配额判定（免费档 4 人边界）")
struct MemberQuotaTests {

    @Test func 第五个成员越限() {
        #expect(PaywallRules.addingMemberWouldExceed(currentCount: 4) == true,
                "已有 4 人时加第 5 个成员越过免费配额")
    }

    @Test func 四人以内不越限() {
        for count in 0...3 {
            #expect(PaywallRules.addingMemberWouldExceed(currentCount: count) == false,
                    "免费档 ≥4 人（FR3.7 边界），已有 \(count) 人时不弹墙")
        }
    }
}

// binds: SU-M1c-SENSITIVE — BR-007/008 重锁策略（FR8.4 / tech-spec §5.10）
@Suite("SU-M1c-SENSITIVE · 敏感媒体重锁策略（BR-007/008）")
struct MediaUnlockPolicyTests {
    @Test func 阈值为规格规定的30秒() {
        #expect(MediaUnlockPolicy.idleTTL == 30)
    }

    /// 计时以「最后一次交互」为起点：正在读图的用户不得被打断
    @Test func 按无操作计时而非解锁时刻() {
        let unlocked = Date(timeIntervalSince1970: 1_000_000)
        let stillReading = unlocked.addingTimeInterval(100)   // 解锁 100s 后仍在交互
        #expect(!MediaUnlockPolicy.shouldRelock(lastInteraction: stillReading,
                                                now: stillReading.addingTimeInterval(29)))
        #expect(MediaUnlockPolicy.shouldRelock(lastInteraction: stillReading,
                                               now: stillReading.addingTimeInterval(30)))
    }

    @Test func 活跃信号按合并窗口去抖() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        #expect(MediaUnlockPolicy.shouldRecordActivity(lastInteraction: nil, now: t))
        // 同一秒内的高频触摸事件不重复写状态
        #expect(!MediaUnlockPolicy.shouldRecordActivity(lastInteraction: t,
                                                        now: t.addingTimeInterval(0.016)))
        #expect(MediaUnlockPolicy.shouldRecordActivity(lastInteraction: t,
                                                       now: t.addingTimeInterval(1)))
    }

    /// 退后台立即重锁——敏感内容不得出现在任务切换器快照里（BR-007/008）
    @Test func 退后台立即重锁() {
        #expect(MediaUnlockPolicy.shouldRelockOnBackground())
    }
}

// binds: SU-M15-TREND — 无障碍与可见文本的医学数字必须一致
@Suite("M1c · 医学数值显示单一出口（无障碍一致性）")
struct MedicalNumberFormatTests {
    /// 这是该出口存在的理由：**计算得来**的 Double 用字符串插值会念出全部往返精度，
    /// 与屏幕上的 1 位小数不一致——视障用户听到的医学数字必须与看到的相同。
    /// 用参考带下界的真实算式（mean − 1.96·sd）取值，而不是字面量：
    /// 字面量 3.7000000000000002 会被解析成最近的 Double（正好是 3.7），构不成反例。
    @Test func 无障碍文本不得念出浮点尾数() {
        let mean = 4.9, sd = 0.612245
        let lower = mean - 1.96 * sd            // 实测 3.6999998000000005
        #expect("\(lower)".count > 5, "前提：插值确实暴露尾数（实得 \("\(lower)")）")
        #expect(MedicalNumberFormat.oneDecimal(lower) == "3.7")
    }

    @Test func 一位小数口径稳定() {
        #expect(MedicalNumberFormat.oneDecimal(120) == "120.0")
        #expect(MedicalNumberFormat.oneDecimal(120.44) == "120.4")
        #expect(MedicalNumberFormat.oneDecimal(120.45) == "120.5")
        #expect(MedicalNumberFormat.oneDecimal(-0.04) == "-0.0")
    }

    /// 件数口径：整数不带小数点（保持既有用户可见形态）
    @Test func 件数口径保持既有形态() {
        #expect(MedicalNumberFormat.quantity(3) == "3")
        #expect(MedicalNumberFormat.quantity(4.5) == "4.5")
    }

    /// 两个口径都不受设备区域影响（String(format:) 默认 POSIX，非当前 locale）
    @Test func 不随设备区域改变小数点() {
        #expect(MedicalNumberFormat.oneDecimal(1.5).contains("."))
        #expect(!MedicalNumberFormat.oneDecimal(1.5).contains(","))
        #expect(!MedicalNumberFormat.quantity(1.5).contains(","))
    }
}
