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

@Suite("M1c · 本地检索式 AI（§5.5/BR-006/BR-012）")
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
        #expect(p.disclaimer.contains("不能替代医生"))
        #expect(!p.scopeNote.isEmpty)
    }

    @Test func 术语词典独立于信源库() {
        #expect(TerminologyStore.shared.explain("收缩压") != nil)
        #expect(TerminologyStore.shared.explain("不存在的术语") == nil)
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
}

@Suite("M1c · 观察聚合与就诊展示（§5.36/F8）")
struct ObservationServiceTests {
    @Test func 同组聚合与成员隔离() {
        let me = UUID()
        let other = UUID()
        let g = UUID()
        let events = [
            ObservationEvent(id: UUID(), groupId: g, kind: "skin", occurredAt: Date(timeIntervalSince1970: 100),
                             description: "红疹", selfMark: "worsened", memberId: me),
            ObservationEvent(id: UUID(), groupId: g, kind: "skin", occurredAt: Date(timeIntervalSince1970: 200),
                             description: "消退", selfMark: "improved", memberId: me),
            ObservationEvent(id: UUID(), kind: "skin", occurredAt: Date(timeIntervalSince1970: 300),
                             description: "他人", selfMark: nil, memberId: other),
        ]
        let groups = ObservationGroupService.groups(events, member: me)
        #expect(groups.count == 1)
        #expect(groups[0].occurrences.count == 2)
        #expect(groups[0].selfMark == "improved")   // 最新自评
    }

    @Test func 展示会话超时自动重锁与scope过滤() {
        let me = UUID()
        let event = ObservationEvent(id: UUID(), kind: "skin", occurredAt: Date(),
                                     description: "红疹", selfMark: nil, memberId: me)
        let session = DoctorShowcaseSession(patientId: me, unlockedAt: Date(timeIntervalSince1970: 0),
                                            timeoutSeconds: 300, scopeKind: "skin")
        #expect(!session.isActive(at: Date(timeIntervalSince1970: 400)))   // 超时重锁
        #expect(DoctorShowcaseRules.visibleEvents([event], session: session,
                                                  now: Date(timeIntervalSince1970: 400)).isEmpty)
        let activeSession = DoctorShowcaseSession(patientId: me, unlockedAt: Date(timeIntervalSince1970: 0),
                                                  timeoutSeconds: 300, scopeKind: "urine")
        #expect(DoctorShowcaseRules.visibleEvents([event], session: activeSession,
                                                  now: Date(timeIntervalSince1970: 100)).isEmpty)  // scope 过滤
    }
}
