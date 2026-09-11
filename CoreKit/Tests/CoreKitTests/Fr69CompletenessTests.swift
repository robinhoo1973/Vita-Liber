import Foundation
import Testing
@testable import Domain
#if os(iOS) || os(macOS)
import GRDB   // 平台边界（ERR#8）：GRDB 仅 iOS/macOS 链接，Linux 只跑 Domain 门禁
@testable import Infrastructure
#endif

// binds: SU-M2-PENDINGCARD
@Suite("SU-M2-PENDINGCARD · FR6.9 完整度评估与聚合中心（data-flow §17/§4.5.1）")
struct Fr69CompletenessTests {

    // MARK: - §17.1.2 评估公式金样（四级完整度）

    private func field(_ key: String, _ confidence: Double = 0.95) -> FieldDraft {
        FieldDraft(key: key, value: "值-\(key)", confidence: confidence)
    }

    @Test("处方 required+recommended 全识别高置信 → 完整（§17.1.2 公式）")
    func 处方完整() {
        let a = CompletenessEvaluator.assess(
            fields: [field("drug_name"), field("prescribed_at"),
                     field("hospital"), field("doctor"), field("advice_text")],
            cardKind: "prescription")
        #expect(a.level == .complete)
        #expect(a.score >= 0.85)
        #expect(a.missingFields.isEmpty)
    }

    @Test("required 全识别但推荐字段缺失 → 基本完整（公式：缺失项权重拉低 score）")
    func 处方基本完整() {
        let a = CompletenessEvaluator.assess(
            fields: [field("drug_name"), field("prescribed_at")], cardKind: "prescription")
        #expect(a.level == .basicallyComplete)
        #expect(a.missingFields.count == 3)
    }

    @Test("required 全识别但存在低置信 → 基本完整")
    func 处方基本完整低置信() {
        let a = CompletenessEvaluator.assess(
            fields: [field("drug_name", 0.6), field("prescribed_at", 0.95),
                     field("hospital"), field("doctor"), field("advice_text")],
            cardKind: "prescription")
        #expect(a.level == .basicallyComplete)
        #expect(a.lowConfidenceFields.contains("drug_name"))
    }

    @Test("≥50% required 识别且 score ≥ 0.4 → 部分完整（可跳过稍后）")
    func 处方部分完整() {
        let a = CompletenessEvaluator.assess(
            fields: [field("drug_name"), field("hospital"), field("doctor")],
            cardKind: "prescription")
        #expect(a.level == .partiallyComplete)
        #expect(a.requiredCoverage >= 0.5)
    }

    @Test("<50% required 识别 → 严重缺失（不建卡）")
    func 处方严重缺失() {
        let a = CompletenessEvaluator.assess(
            fields: [field("hospital")], cardKind: "prescription")
        #expect(a.level == .severelyIncomplete)
    }

    @Test("未登记卡种（系统自动生成实体）→ 无规则恒完整")
    func 未登记卡种() {
        let a = CompletenessEvaluator.assess(fields: [], cardKind: "alert_event")
        #expect(a.level == .complete)
    }

    @Test("metric_sample 语音路径：4 必填全识别、推荐缺失 → 基本完整（公式口径）")
    func 指标完整() {
        let a = CompletenessEvaluator.assess(
            fields: [field("metric_key"), field("value"), field("unit"), field("measured_at")],
            cardKind: "metric_sample")
        #expect(a.level == .basicallyComplete)
        let b = CompletenessEvaluator.assess(
            fields: [field("metric_key"), field("value"), field("unit"), field("measured_at"),
                     field("ref_low"), field("ref_high"), field("raw_label"), field("code_concept_id")],
            cardKind: "metric_sample")
        #expect(b.level == .complete)
    }

    // MARK: - 处方 OCR 路径键归一（标签身份 → §17.2 稳定键）

    private var labels: PrescriptionFieldMapper.Labels {
        PrescriptionFieldMapper.Labels(hospital: "医院", doctor: "医生",
                                       frequency: "频次", dosage: "剂量",
                                       drugName: "药品名", other: "其他")
    }

    @Test("处方 OCR 标签行归一：药品名+日期行 → 基本完整（推荐缺失按公式降级）")
    func 处方键归一() {
        let fields = [
            CandidateField(key: "rx_line_0", displayLabel: "药品名",
                           rawText: "阿莫西林胶囊", confidence: 0.9),
            CandidateField(key: "rx_line_1", displayLabel: "其他",
                           rawText: "2026-01-15", confidence: 0.9),
        ]
        let drafts = CompletenessEvaluator.prescriptionFieldDrafts(fields: fields, labels: labels)
        let keys = Set(drafts.map(\.key))
        #expect(keys.contains("drug_name"))
        #expect(keys.contains("prescribed_at"))
        let a = CompletenessEvaluator.assess(fields: drafts, cardKind: "prescription")
        #expect(a.level == .basicallyComplete)
    }

    @Test("处方 OCR 仅药品名（无日期/医院/医生）→ 严重缺失（公式：score<0.4）")
    func 处方键归一缺日期() {
        let fields = [
            CandidateField(key: "rx_line_0", displayLabel: "药品名",
                           rawText: "阿莫西林胶囊", confidence: 0.9),
        ]
        let drafts = CompletenessEvaluator.prescriptionFieldDrafts(fields: fields, labels: labels)
        let a = CompletenessEvaluator.assess(fields: drafts, cardKind: "prescription")
        #expect(a.level == .severelyIncomplete)
    }

    @Test("处方 OCR 药品名+医院+医生缺日期 → 部分完整（可跳过稍后）")
    func 处方键归一可跳过() {
        let fields = [
            CandidateField(key: "rx_line_0", displayLabel: "药品名",
                           rawText: "阿莫西林胶囊", confidence: 0.9),
            CandidateField(key: "rx_line_1", displayLabel: "医院",
                           rawText: "市一医院", confidence: 0.9),
            CandidateField(key: "rx_line_2", displayLabel: "医生",
                           rawText: "王医生", confidence: 0.9),
        ]
        let drafts = CompletenessEvaluator.prescriptionFieldDrafts(fields: fields, labels: labels)
        let a = CompletenessEvaluator.assess(fields: drafts, cardKind: "prescription")
        #expect(a.level == .partiallyComplete)
    }

    // MARK: - ReminderAggregationCenter（§4.5.1/§5.33 V3.96）

    private func item(_ kind: String, _ sourceId: String, kind ag: AggregationKind,
                      at: Date, priority: Int = 0, patient: UUID? = nil,
                      plan: String? = nil) -> AggregatedReminderItem {
        AggregatedReminderItem(
            id: .init(kind: kind, sourceId: sourceId), aggregationKind: ag,
            occurredAt: at, title: "t-\(sourceId)", patientID: patient,
            priority: priority, planID: plan)
    }

    @Test("source_kind+source_id 去重：重复项只保留首个")
    func 去重() {
        let now = Date()
        let items = [
            item("reminder", "r1", kind: .medication, at: now),
            item("reminder", "r1", kind: .medication, at: now),
            item("reminder", "r2", kind: .medication, at: now),
        ]
        let out = ReminderAggregationCenter.aggregate(items, memberId: UUID())
        #expect(out.count == 2)
    }

    @Test("置顶项（priority≥2：SOS/L1+/高风险 OCR）绕过窗口与成员过滤")
    func 置顶绕过() {
        let now = Date()
        let pinned = item("sos", "s1", kind: .sos,
                          at: now.addingTimeInterval(-20 * 86400), priority: 3, patient: UUID())
        let out = ReminderAggregationCenter.aggregate([pinned], memberId: UUID())
        #expect(out.count == 1)
        #expect(out[0].isPinned)
    }

    @Test("时间窗过滤：窗外普通项剔除")
    func 时间窗() {
        let now = Date()
        let stale = item("reminder", "r-old", kind: .medication,
                         at: now.addingTimeInterval(-30 * 86400))
        let fresh = item("reminder", "r-new", kind: .medication,
                         at: now.addingTimeInterval(-3600))
        let out = ReminderAggregationCenter.aggregate([stale, fresh], memberId: UUID())
        #expect(out.map(\.id.sourceId) == ["r-new"])
    }

    @Test("成员隔离（BR-001）：他成员普通项剔除、置顶保留")
    func 成员隔离() {
        let now = Date()
        let other = item("reminder", "r-other", kind: .medication, at: now,
                         patient: UUID())
        let mine = item("reminder", "r-mine", kind: .medication, at: now,
                        patient: UUID())
        let me = mine.patientID ?? UUID()
        let out = ReminderAggregationCenter.aggregate([other, mine], memberId: me)
        #expect(out.count == 1)
        #expect(out[0].id.sourceId == "r-mine")
    }

    @Test("首日引导优先级（I7）：仅资料完善 → 引导；任一真实提醒 → 聚合列表")
    func 首日引导优先级() {
        let now = Date()
        let progress = item("profile_progress", "p1", kind: .system, at: now)
        // 只有资料完善任务：新用户 → 展示引导；老用户 → 不展示
        #expect(ReminderAggregationCenter.showsFirstDayGuide(items: [progress], isNewUser: true, progressKind: "profile_progress"))
        #expect(!ReminderAggregationCenter.showsFirstDayGuide(items: [progress], isNewUser: false, progressKind: "profile_progress"))
        // 出现任一真实提醒（哪怕普通服药提醒）→ 引导让位聚合列表
        let real = item("reminder", "r1", kind: .medication, at: now)
        #expect(!ReminderAggregationCenter.showsFirstDayGuide(items: [progress, real], isNewUser: true, progressKind: "profile_progress"))
        // 空聚合 + 新用户 → 引导（allSatisfy 空集恒真，与 V3.39 空态语义一致）
        #expect(ReminderAggregationCenter.showsFirstDayGuide(items: [], isNewUser: true, progressKind: "profile_progress"))
    }

    @Test("周期计划压缩：同 plan 保留最近逾期+下一未来项并附剩余数")
    func 周期计划压缩() {
        let now = Date()
        let plan = UUID().uuidString
        // 每个剂量实例是独立 sourceId（去重键 source_kind+source_id 不折叠实例），
        // planID 相同 → (planID, window) 压缩键生效
        let items = [
            item("dose", "\(plan)#1", kind: .medication, at: now.addingTimeInterval(-7200), plan: plan),
            item("dose", "\(plan)#2", kind: .medication, at: now.addingTimeInterval(-3600), plan: plan),
            item("dose", "\(plan)#3", kind: .medication, at: now.addingTimeInterval(3600), plan: plan),
            item("dose", "\(plan)#4", kind: .medication, at: now.addingTimeInterval(7200), plan: plan),
        ]
        let out = ReminderAggregationCenter.aggregate(items, memberId: UUID())
        #expect(out.count == 2)
        #expect(out.allSatisfy { ($0.remainingCount ?? 0) == 2 })
        let times = out.map(\.occurredAt).sorted()
        #expect(times[0] == now.addingTimeInterval(-3600))
        #expect(times[1] == now.addingTimeInterval(3600))
    }

    @Test("排序：priority desc 再按时间 desc")
    func 排序() {
        let now = Date()
        let low = item("reminder", "r1", kind: .medication, at: now, priority: 0)
        let high = item("alert", "a1", kind: .alert, at: now.addingTimeInterval(-7200), priority: 2)
        let out = ReminderAggregationCenter.aggregate([low, high], memberId: UUID())
        #expect(out[0].id.sourceId == "a1")
        #expect(out[1].id.sourceId == "r1")
    }

    @Test("待办卡投影：非敏感标题/24h 时效/状态透传（data-flow §20.1）")
    func 待办卡投影() {
        let now = Date()
        let projected = ReminderAggregationCenter.pendingCardItem(
            cardId: "c1", cardKind: "prescription", patientId: UUID(),
            createdAt: now, status: "pending")
        #expect(projected.aggregationKind == .pendingCard)
        #expect(projected.title == "待补充：prescription")
        #expect(projected.dueDate == now.addingTimeInterval(24 * 3600))
        #expect(projected.status == "pending")
    }

    @Test("类别筛选：置顶项恒保留、其余按类别（V3.87 纯 View 参数）")
    func 类别筛选() {
        let now = Date()
        let alert = item("alert", "a1", kind: .alert, at: now, priority: 2)
        let card = item("pending_card", "c1", kind: .pendingCard, at: now)
        let all = ReminderAggregationCenter.aggregate([alert, card], memberId: UUID())
        let filtered = ReminderAggregationCenter.filtered(all, kind: .pendingCard)
        #expect(filtered.map(\.id.sourceId).sorted() == ["a1", "c1"])
    }
}

// binds: SU-M2-PENDINGCARD-DB
// GRDB 平台边界（ERR#8，同 GoldenMigrationTests）：仅 iOS/macOS 执行，
// Linux 只跑 Domain 门禁；SchemaV2 baseline 含 pending_card 全量 DDL。
#if os(iOS) || os(macOS)
@Suite("SU-M2-PENDINGCARD-DB · FR6.9 §21.1 手工草稿同源去重")
struct PendingCardDedupTests {
    @Test("无文档 ID 重复跳过复用同卡（同成员+卡种+原文）")
    func 无文档ID重复跳过复用同卡() async throws {
        let dbQueue = try DatabaseQueue(configuration: GRDBStore.configuration())
        // GRDB 重载纪律：async 测试函数内 write 解析到 async 重载须 await
        // （GoldenMigrationTests 同步函数用同步重载无此问题——L1 34299153156 族）
        let patient = UUID()
        try await dbQueue.write { db in
            try db.execute(sql: SchemaV2.ddl)
            // 外键纪律（L0 [3] 恒开）：pending_card.patient_id REFERENCES
            // patient_profile(id)——先落成员行再建卡（L1 34299816294 族）
            try db.execute(sql: """
                INSERT INTO patient_profile
                  (id, display_name, relation, created_at, updated_at)
                VALUES (?, '王女士', 'self', ?, ?)
                """, arguments: [patient.uuidString, Date().timeIntervalSince1970,
                                 Date().timeIntervalSince1970])
        }
        let store = PendingCardStore(writer: dbQueue)   // actor init 非隔离，同步可调
        let draft = PendingCardDraft(patientId: patient, sourceType: "manual", sourceDocId: nil,
                                     cardKind: "prescription",
                                     incompleteFields: [IncompleteField(key: "dosage", confidence: 0.5)],
                                     partialData: ["drug_name": "阿莫西林"],
                                     rawText: "阿莫西林 每日三次")
        let first = try await store.upsert(draft)
        let second = try await store.upsert(draft)
        #expect(first == second)
        let cards = try await store.list(patientId: patient)
        #expect(cards.count == 1)
    }
}
#endif
