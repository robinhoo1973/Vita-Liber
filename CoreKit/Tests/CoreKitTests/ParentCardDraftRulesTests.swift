import Foundation
import Testing
@testable import Domain

// binds: SU-M2-PENDINGCARD
/// 子项目 J · J2（round1 §E.5 / recognition-remediation-design §0.4 改判）：识别出的子卡永远有父——无可挂接主卡 →
/// 主卡草稿（D 级，与子卡同流确认、同事务落库）；只搬子卡共享字段**原文**，不推断；`kind` 只由文档类型键派生；
/// `EncounterResolver.suggest` 命中（±3 日同医院）的预选优先于草稿。纯 Domain，Linux 可跑。
@Suite("FR6.9 主卡草稿派生")
struct ParentCardDraftRulesTests {
    func card(_ kind: String, shared: [(String, String)], rows: [[(String, String)]] = [[("drug_name", "阿莫西林")]]) -> MatchedCard {
        MatchedCard(kind: kind, pageIndex: 0, shared: shared.map { FieldDraft(key: $0.0, value: $0.1) },
                    rows: rows.map { MatchedCardRow(fields: $0.map { FieldDraft(key: $0.0, value: $0.1) }) },
                    allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
    }
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    @Test func 处方卡派生就诊草稿_字段原文_kind按文档键() throws {
        let rx = card("prescription", shared: [("prescribed_at", "2024-03-01"), ("hospital", "市一院"), ("department", "呼吸内科"), ("doctor", "王医生"), ("clinical_diagnosis", "急性支气管炎")])
        let draft = try #require(ParentCardDraftRules.deriveHub(from: rx, documentTypeKey: "prescription"))
        #expect(draft.hub == .encounter)
        #expect(Dictionary(uniqueKeysWithValues: draft.fields.map { ($0.key, $0.value) })
                == ["date": "2024-03-01", "hospital": "市一院", "department": "呼吸内科", "doctor": "王医生", "diagnosis_text": "急性支气管炎", "kind": "outpatient"])
        #expect(draft.fields.allSatisfy { $0.grade == .ocrUnconfirmed }, "草稿恒 D 级")
        #expect(draft.fields.allSatisfy { !$0.isConfirmed })
        #expect(draft.evidence == EncounterResolver.evidenceKey(for: rx))
        #expect(ParentCardDraftRules.deriveHub(from: rx, documentTypeKey: "emergency_record")?.fields.first { $0.key == "kind" }?.value == "emergency")
        #expect(draft.dateKey == "date" && draft.hasDate)
    }

    @Test func 就诊类型只由文档键派生_出院小结手术为住院_日间手术为daySurgery_无键为门诊() throws {
        let surgery = card("surgery", shared: [("surgery_at", "2024-03-01"), ("hospital", "市一院"), ("department", "普外科"), ("surgeon", "张主刀")], rows: [[]])
        #expect(ParentCardDraftRules.deriveHub(from: surgery, documentTypeKey: "discharge_summary")?.fields.first { $0.key == "kind" }?.value == "inpatient")
        #expect(ParentCardDraftRules.deriveHub(from: surgery, documentTypeKey: "day_surgery_record")?.fields.first { $0.key == "kind" }?.value == "daySurgery")
        #expect(ParentCardDraftRules.deriveHub(from: surgery, documentTypeKey: "surgery_record")?.fields.first { $0.key == "kind" }?.value == "outpatient", "无场景证据 → 门诊默认（Picker 可改）")
        let keys = try #require(ParentCardDraftRules.deriveHub(from: surgery, documentTypeKey: nil)).fields.map(\.key)
        #expect(keys == ["date", "hospital", "department", "kind"], "surgeon 不是就诊医生：不跨字段推断（只搬映射表内字段）")
        let treatment = card("treatment_record", shared: [("treated_at", "2024-03-02"), ("hospital", "社区医院"), ("doctor", "王"), ("diagnosis_text", "急性支气管炎")], rows: [[]])
        let t = try #require(ParentCardDraftRules.deriveHub(from: treatment, documentTypeKey: "treatment_record"))
        #expect(Dictionary(uniqueKeysWithValues: t.fields.map { ($0.key, $0.value) }) == ["date": "2024-03-02", "hospital": "社区医院", "doctor": "王", "diagnosis_text": "急性支气管炎", "kind": "outpatient"])
        let dx = card("diagnosis", shared: [("diagnosed_at", "2024-01-09"), ("hospital", "市一院")], rows: [[("name", "高血压")]])
        #expect(ParentCardDraftRules.deriveHub(from: dx, documentTypeKey: "outpatient_record")?.fields.map(\.key) == ["date", "hospital", "kind"])
        let exam = card("exam_report", shared: [("report_type", "ct"), ("exam_at", "2024-01-03"), ("hospital", "市一院"), ("impression", "正常")], rows: [[]])
        #expect(ParentCardDraftRules.hub(for: exam, documentTypeKey: "exam_report") == .encounter)
        #expect(ParentCardDraftRules.deriveHub(from: exam, documentTypeKey: "exam_report")?.fields.first { $0.key == "date" }?.value == "2024-01-03")
    }

    @Test func 结论卡与体检页检验卡派生体检草稿() throws {
        let conclusion = card("clinical_conclusion", shared: [("org_name", "美年体检"), ("exam_date", "2024-05-06"), ("exam_no", "TJ001")], rows: [[("content", "血脂偏高")]])
        let draft = try #require(ParentCardDraftRules.deriveHub(from: conclusion, documentTypeKey: nil))
        #expect(draft.hub == .healthExam && draft.fields.map(\.key) == ["exam_date", "org_name", "exam_no"])
        #expect(draft.dateKey == "exam_date" && draft.hasDate)
        let lab = card("metric_sample", shared: [("measured_at", "2024-05-06"), ("hospital", "美年体检")], rows: [[("raw_label", "白细胞"), ("value", "6.5")]])
        #expect(ParentCardDraftRules.hub(for: lab, documentTypeKey: "checkup_report") == .healthExam)
        #expect(ParentCardDraftRules.hub(for: lab, documentTypeKey: "lab_report") == .encounter)
        let labDraft = try #require(ParentCardDraftRules.deriveHub(from: lab, documentTypeKey: "checkup_report"))
        #expect(Dictionary(uniqueKeysWithValues: labDraft.fields.map { ($0.key, $0.value) }) == ["exam_date": "2024-05-06", "org_name": "美年体检"], "医院名搬作机构名（映射），编号不臆造")
        let exam = card("exam_report", shared: [("report_type", "ultrasound"), ("exam_at", "2024-05-06"), ("hospital", "美年体检"), ("impression", "肝囊肿")], rows: [[]])
        #expect(ParentCardDraftRules.hub(for: exam, documentTypeKey: "checkup_report") == .healthExam)
        #expect(ParentCardDraftRules.hub(for: card("health_exam", shared: [("org_name", "A")]), documentTypeKey: "checkup_report") == nil, "体检主卡自身不派生")
    }

    @Test func 无枢纽卡类不派生() {
        #expect(ParentCardDraftRules.deriveHub(from: card("immunization", shared: [("provider", "社区医院")]), documentTypeKey: "vaccine_record") == nil, "FR4.6 预防保健档案")
        #expect(ParentCardDraftRules.deriveHub(from: card("medication", shared: []), documentTypeKey: "medication_label") == nil)
        #expect(ParentCardDraftRules.deriveHub(from: card("encounter", shared: [("date", "2024-01-01")]), documentTypeKey: nil) == nil, "主卡自身不派生")
        #expect(ParentCardDraftRules.deriveHub(from: card("hospitalization", shared: [("hospital", "A"), ("kind", "inpatient")]), documentTypeKey: "inpatient_record") == nil, "住院期由住院卡自身建就诊")
        #expect(ParentCardDraftRules.hub(for: card("appointment", shared: []), documentTypeKey: nil) == nil)
    }

    @Test func 草稿转就诊须字段已确认且有日期() throws {
        var draft = try #require(ParentCardDraftRules.deriveHub(from: card("prescription", shared: [("prescribed_at", "2024-03-01"), ("hospital", "市一院")]), documentTypeKey: nil))
        #expect(ParentCardDraftRules.encounterDraft(from: draft, patientId: UUID(), calendar: .init(identifier: .gregorian)) == nil, "未确认 → nil（BR-003）")
        #expect(!draft.isComplete(calendar: utc))
        for i in draft.fields.indices { _ = draft.fields[i].confirm() }
        #expect(draft.isComplete(calendar: utc))
        let patient = UUID()
        let enc = try #require(ParentCardDraftRules.encounterDraft(from: draft, patientId: patient, calendar: .init(identifier: .gregorian)))
        #expect(enc.kind == "outpatient" && enc.hospital == "市一院" && enc.patientId == patient && enc.department == nil && enc.doctor == nil && enc.diagnosisText == nil)
        #expect(enc.date == Calendar(identifier: .gregorian).date(from: DateComponents(year: 2024, month: 3, day: 1)))
        var noDate = try #require(ParentCardDraftRules.deriveHub(from: card("claim_item", shared: [("merchant", "市一院")]), documentTypeKey: nil))
        #expect(noDate.fields.map(\.key) == ["hospital", "kind"] && !noDate.hasDate)
        for i in noDate.fields.indices { _ = noDate.fields[i].confirm() }
        #expect(!noDate.isComplete(calendar: utc))
        #expect(ParentCardDraftRules.encounterDraft(from: noDate, patientId: UUID(), calendar: .init(identifier: .gregorian)) == nil, "无日期不建就诊，由确认页要求补填")
        var badKind = draft
        if let i = badKind.fields.firstIndex(where: { $0.key == "kind" }) { badKind.fields[i].revise(to: "spa"); _ = badKind.fields[i].confirm() }
        #expect(ParentCardDraftRules.encounterDraft(from: badKind, patientId: UUID(), calendar: utc) == nil, "kind 须为 EncounterKind 枚举")
        #expect(ParentCardDraftRules.healthExamDraft(from: draft, patientId: UUID(), calendar: utc) == nil, "枢纽不符")
    }

    @Test func 草稿转体检须字段已确认且有日期_机构编号原文() throws {
        var draft = try #require(ParentCardDraftRules.deriveHub(from: card("clinical_conclusion", shared: [("org_name", "美年体检"), ("exam_date", "2024年5月6日"), ("exam_no", "TJ001")], rows: [[("content", "A")]]), documentTypeKey: nil))
        #expect(ParentCardDraftRules.healthExamDraft(from: draft, patientId: UUID(), calendar: utc) == nil, "未确认 → nil（BR-003）")
        for i in draft.fields.indices { _ = draft.fields[i].confirm() }
        let patient = UUID()
        let exam = try #require(ParentCardDraftRules.healthExamDraft(from: draft, patientId: patient, calendar: utc))
        #expect(exam.patientId == patient && exam.orgName == "美年体检" && exam.examNo == "TJ001" && exam.examDate == utc.date(from: DateComponents(year: 2024, month: 5, day: 6)))
        #expect(exam.source == .ocr && exam.confirmed == true && exam.documentFileId == nil && exam.heightText == nil, "草稿只带表头三字段；document/时间戳由 store 填")
        #expect(ParentCardDraftRules.encounterDraft(from: draft, patientId: patient, calendar: utc) == nil, "枢纽不符")
        var undated = try #require(ParentCardDraftRules.deriveHub(from: card("clinical_conclusion", shared: [("org_name", "美年体检")], rows: [[("content", "A")]]), documentTypeKey: nil))
        for i in undated.fields.indices { _ = undated.fields[i].confirm() }
        #expect(ParentCardDraftRules.healthExamDraft(from: undated, patientId: patient, calendar: utc) == nil)
    }

    @Test func 关联裁决_解析器命中预选优先_否则草稿_无枢纽卡类为未选择() throws {
        let patient = UUID(), enc = UUID()
        let rx = card("prescription", shared: [("prescribed_at", "2024-03-01"), ("hospital", "市一院")])
        let sameHospital = EncounterResolver.Candidate(id: enc, patientId: patient, date: utc.date(from: DateComponents(year: 2024, month: 3, day: 2))!, hospital: "市一院", doctor: nil)
        let hit = ParentCardDraftRules.association(for: rx, documentTypeKey: "prescription", patientId: patient, candidates: [sameHospital], calendar: utc)
        #expect(hit == .suggested(enc, evidence: EncounterResolver.evidenceKey(for: rx)), "±3 日同医院 → 证据化预选优先于草稿")
        let farAway = EncounterResolver.Candidate(id: enc, patientId: patient, date: utc.date(from: DateComponents(year: 2024, month: 3, day: 9))!, hospital: "市一院", doctor: nil)
        let miss = ParentCardDraftRules.association(for: rx, documentTypeKey: "prescription", patientId: patient, candidates: [farAway], calendar: utc)
        guard case .newHub(let draft) = miss else { Issue.record("无命中须回落主卡草稿"); return }
        #expect(draft.hub == .encounter && draft.fields.first { $0.key == "hospital" }?.value == "市一院")
        let foreign = EncounterResolver.Candidate(id: enc, patientId: UUID(), date: sameHospital.date, hospital: "市一院", doctor: nil)
        #expect({ if case .newHub = ParentCardDraftRules.association(for: rx, documentTypeKey: nil, patientId: patient, candidates: [foreign], calendar: utc) { return true }; return false }(), "跨成员候选不预选（BR-001）")
        #expect(ParentCardDraftRules.association(for: card("immunization", shared: [("provider", "社区医院")]), documentTypeKey: "vaccine_record", patientId: patient, candidates: [sameHospital], calendar: utc) == .unselected)
        let conclusion = card("clinical_conclusion", shared: [("org_name", "市一院"), ("exam_date", "2024-03-01")], rows: [[("content", "A")]])
        #expect({ if case .newHub(let d) = ParentCardDraftRules.association(for: conclusion, documentTypeKey: "checkup_report", patientId: patient, candidates: [sameHospital], calendar: utc) { return d.hub == .healthExam }; return false }(),
                "体检枢纽不走就诊解析器")
    }

    @Test func 关联枚举新增两态可往返_就诊id与枢纽id语义() throws {
        let hub = UUID(), draft = try #require(ParentCardDraftRules.deriveHub(from: card("prescription", shared: [("prescribed_at", "2024-03-01"), ("hospital", "市一院")]), documentTypeKey: nil))
        for association in [EncounterAssociation.newHub(draft), .existingHub(.healthExam, hub), .existingHub(.encounter, hub), .existing(hub), .suggested(hub, evidence: "x"), .none, .unselected] {
            let data = try JSONEncoder().encode(association)
            #expect(try JSONDecoder().decode(EncounterAssociation.self, from: data) == association)
        }
        #expect(EncounterAssociation.newHub(draft).encounterID == nil && EncounterAssociation.newHub(draft).hubID == nil, "草稿尚无 id")
        let examHub = EncounterAssociation.existingHub(.healthExam, hub)
        #expect(examHub.encounterID == nil && examHub.hubID?.hub == .healthExam && examHub.hubID?.id == hub, "体检枢纽不是就诊")
        #expect(EncounterAssociation.existingHub(.hospitalization, hub).encounterID == hub && EncounterAssociation.existingHub(.encounter, hub).encounterID == hub)
        #expect(EncounterAssociation.existing(hub).hubID?.hub == .encounter && EncounterAssociation.existing(hub).hubID?.id == hub)
        #expect(EncounterAssociation.suggested(hub, evidence: "e").hubID?.hub == .encounter && EncounterAssociation.none.hubID == nil && EncounterAssociation.unselected.hubID == nil)
        // 既有编码形态不变（旧 pending 快照可解）
        #expect(try JSONDecoder().decode(EncounterAssociation.self, from: Data(#"{"none":{}}"#.utf8)) == .none)
        var edited = card("prescription", shared: [("prescribed_at", "2024-03-01"), ("hospital", "市一院")], rows: [[("drug_name", "A")]])
        edited.encounterAssociation = .newHub(draft)
        edited.reviseField(at: 1, to: "市二院")
        #expect(edited.encounterAssociation == .unselected, "证据字段被编辑 → 草稿失效回未选择（与 .suggested 同纪律）")
    }
}
