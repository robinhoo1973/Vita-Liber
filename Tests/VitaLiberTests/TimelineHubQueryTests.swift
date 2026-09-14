import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols

/// v27 子项目 J · round1 §E.7 V4/V5：主卡分页 + 子卡批取（`TimelineQueryStore.hubPage`）。
/// 旧平铺查询 `entries(for:)` 的平铺语义由 `M1cAcceptanceTests` 守住（分支集合不改），本套件只以一条断言复核其不受影响。
/// CI-only（GRDB / XCTest）。
@MainActor
// binds: SU-M1c-REGRESSION（FR11.1 / FR11.2 / BR-001 / BR-003）
final class TimelineHubQueryTests: XCTestCase {
    /// 与 M1cAcceptanceTests.makeStore 同构：只建成员，不建文档（文档叶子会改变计数）。
    private func makeStore() async throws -> (GRDBStore, UUID) {
        let store = try GRDBStore.inMemory(), patient = UUID()
        try await store.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'A', 'self', 0, 0)",
                           arguments: [patient.uuidString])
        }
        return (store, patient)
    }

    private func encounter(_ db: GRDBStore, patient: UUID, at seconds: Double, kind: String = "outpatient", hospital: String? = nil) async throws -> UUID {
        try await EncounterStore(writer: db.writer).upsert(encounter: .init(patientId: patient, date: Date(timeIntervalSince1970: seconds), kind: kind, hospital: hospital))
    }

    func test_hubPage_groupsChildrenUnderEncounterAndKeepsLeaves() async throws {
        let (db, patient) = try await makeStore()
        let enc = try await encounter(db, patient: patient, at: 1_700_000_000)
        try await db.writer.write { d in
            try d.execute(sql: "INSERT INTO prescription (id, patient_id, encounter_id, source, prescribed_at, confirmed, created_at, updated_at) VALUES (?, ?, ?, 'manual', 1700000000, 1, 0, 0)",
                          arguments: [UUID().uuidString, patient.uuidString, enc.uuidString])
            try d.execute(sql: "INSERT INTO lab_report (id, patient_id, encounter_id, hospital, reported_at, source, confirmed, created_at, updated_at) VALUES (?, ?, ?, '市一院', 1700000000, 'ocr', 1, 0, 0)",
                          arguments: [UUID().uuidString, patient.uuidString, enc.uuidString])
            // 复诊预约在未来：作为子卡列出，但不推走主卡位置（子卡日期不参与游标）
            try d.execute(sql: "INSERT INTO appointment (id, patient_id, hospital, department, starts_at, status, encounter_id, purpose, created_at, updated_at) VALUES (?, ?, '市一院', '呼吸内科', 1701000000, 'scheduled', ?, 'followUp', 0, 0)",
                          arguments: [UUID().uuidString, patient.uuidString, enc.uuidString])
            try d.execute(sql: "INSERT INTO observation (id, patient_id, kind, occurred_at, description, created_at, updated_at) VALUES (?, ?, 'skin', 1699990000, '红疹', 0, 0)",
                          arguments: [UUID().uuidString, patient.uuidString])
            // D 级（未确认）诊断不入子卡（BR-003）
            try d.execute(sql: "INSERT INTO diagnosis (id, patient_id, encounter_id, name, confirmed, created_at, updated_at) VALUES (?, ?, ?, '待确认', 0, 0, 0)",
                          arguments: [UUID().uuidString, patient.uuidString, enc.uuidString])
        }
        let timeline = TimelineQueryStore(writer: db.writer)
        let page = try await timeline.hubPage(patientId: patient)
        XCTAssertEqual(page.entries.map(\.hub), [.encounter, nil])                      // 就诊主卡（最新）→ 观察叶子
        XCTAssertEqual(page.entries[0].entry.refID, enc)
        XCTAssertEqual(page.entries[0].children.map(\.kind), [.appointment, .prescription, .labReport])   // 日期倒序 → 类型序
        XCTAssertEqual(page.entries[0].counts, [.appointment: 1, .prescription: 1, .labReport: 1])
        XCTAssertEqual(page.entries[1].entry.kind, .observation)
        XCTAssertTrue(page.entries[1].children.isEmpty)
        XCTAssertNil(page.nextCursor)
        XCTAssertTrue(try await timeline.hubPage(patientId: UUID()).entries.isEmpty, "BR-001：跨成员查询必须为空")
        // 旧平铺查询不受影响：就诊 + 观察 = 2（处方 / 检验 / 预约无平铺分支）
        XCTAssertEqual(try await timeline.entries(for: patient).entries.count, 2)
        // 筛选只裁叶子：观察筛选下主卡仍在（可见性由 Domain visible 收窄）
        let filtered = try await timeline.hubPage(patientId: patient, filter: .kinds([.observation]))
        XCTAssertEqual(filtered.entries.map(\.hub), [.encounter, nil])
        XCTAssertEqual(TimelineHierarchyRules.visible(filtered.entries, filter: .kinds([.observation])).map(\.entry.kind), [.observation])
    }

    func test_hubPage_labReportUnderBothEncounterAndHealthExam() async throws {
        let (db, patient) = try await makeStore()
        let enc = try await encounter(db, patient: patient, at: 1_700_100_000)
        let exam = UUID(), lab = UUID()
        try await db.writer.write { d in
            try d.execute(sql: "INSERT INTO health_exam (id, patient_id, org_name, exam_date, overall_conclusion, source, confirmed, created_at, updated_at) VALUES (?, ?, '美年体检', 1700000000, '总检：血脂偏高', 'ocr', 1, 0, 0)",
                          arguments: [exam.uuidString, patient.uuidString])
            try d.execute(sql: "INSERT INTO lab_report (id, patient_id, encounter_id, health_exam_id, report_source, hospital, reported_at, source, confirmed, created_at, updated_at) VALUES (?, ?, ?, ?, 'health_exam', '美年体检', 1700000000, 'ocr', 1, 0, 0)",
                          arguments: [lab.uuidString, patient.uuidString, enc.uuidString, exam.uuidString])
            try d.execute(sql: "INSERT INTO clinical_conclusion (id, patient_id, health_exam_id, conclusion_type, content, severity_text, ordinal, created_at) VALUES (?, ?, ?, 'health_exam_summary', '血脂偏高', '关注', 0, 5)",
                          arguments: [UUID().uuidString, patient.uuidString, exam.uuidString])
            try d.execute(sql: "INSERT INTO clinical_conclusion (id, patient_id, health_exam_id, conclusion_type, content, ordinal, created_at) VALUES (?, ?, ?, 'recheck_advice', '三个月后复查血脂', 1, 6)",
                          arguments: [UUID().uuidString, patient.uuidString, exam.uuidString])
        }
        let page = try await TimelineQueryStore(writer: db.writer).hubPage(patientId: patient)
        XCTAssertEqual(page.entries.map(\.hub), [.encounter, .healthExam])
        XCTAssertEqual(page.entries[1].entry.kind, .healthExam)
        XCTAssertEqual(page.entries[1].entry.title, "美年体检")
        XCTAssertEqual(page.entries[1].entry.summary, "总检：血脂偏高")
        XCTAssertEqual(page.entries[0].children.map(\.refID), [lab], "检验表头挂就诊")
        XCTAssertEqual(page.entries[1].children.map(\.kind), [.labReport, .clinicalConclusion], "多重归属两处都列（C6）；结论聚合为一条子卡")
        XCTAssertEqual(page.entries[1].children.map(\.refID), [lab, exam])
        XCTAssertEqual(page.entries[1].children[1].title, "2")                                   // 结论条数
        XCTAssertEqual(page.entries[1].counts, [.labReport: 1, .clinicalConclusion: 1])
        XCTAssertEqual(page.entries[1].id, "health_exam-healthExam-\(exam.uuidString)")
    }

    func test_hubPage_hospitalizationHubAndOrphanChildAsOwnLeaf() async throws {
        let (db, patient) = try await makeStore()
        let stay = try await encounter(db, patient: patient, at: 1_700_200_000, kind: "inpatient", hospital: "市一院")
        try await db.writer.write { d in
            try d.execute(sql: "INSERT INTO hospitalization (id, patient_id, encounter_id, hospital, admit_at, source, confirmed, created_at, updated_at) VALUES (?, ?, ?, '市一院', 1700200000, 'ocr', 1, 0, 0)",
                          arguments: [UUID().uuidString, patient.uuidString, stay.uuidString])
            try d.execute(sql: "INSERT INTO surgery (id, patient_id, encounter_id, surgery_at, surgery_name, surgeon, source, confirmed, created_at, updated_at) VALUES (?, ?, ?, 1700250000, '腹腔镜胆囊切除术', '王医生', 'ocr', 1, 0, 0)",
                          arguments: [UUID().uuidString, patient.uuidString, stay.uuidString])
            // v27 前已确认、无父的历史处方：叶子自成一行，不臆造主卡（round1 §C 结论 5）
            try d.execute(sql: "INSERT INTO prescription (id, patient_id, source, hospital, prescribed_at, confirmed, created_at, updated_at) VALUES (?, ?, 'ocr', '社区医院', 1700100000, 1, 0, 0)",
                          arguments: [UUID().uuidString, patient.uuidString])
        }
        let page = try await TimelineQueryStore(writer: db.writer).hubPage(patientId: patient)
        XCTAssertEqual(page.entries.map(\.hub), [.hospitalization, nil])
        XCTAssertEqual(page.entries[0].entry.kind, .hospitalization)
        XCTAssertEqual(page.entries[0].entry.summary, "市一院")
        XCTAssertEqual(page.entries[0].children.map(\.kind), [.surgery, .hospitalization])          // 手术（更晚）→ 住院期
        XCTAssertEqual(page.entries[1].entry.kind, .prescription)
        XCTAssertEqual(page.entries[1].entry.title, "社区医院")
        XCTAssertFalse(page.entries[1].isHub)
    }

    func test_hubPage_cursorPagingIsStableAcrossHubsAndLeaves() async throws {
        let (db, patient) = try await makeStore()
        let e3 = try await encounter(db, patient: patient, at: 3_000)
        let e2 = try await encounter(db, patient: patient, at: 2_000)
        let e1 = try await encounter(db, patient: patient, at: 1_000)
        try await db.writer.write { d in
            try d.execute(sql: "INSERT INTO observation (id, patient_id, kind, occurred_at, description, created_at, updated_at) VALUES (?, ?, 'skin', 2500, '红疹', 0, 0)",
                          arguments: [UUID().uuidString, patient.uuidString])
            for enc in [e3, e2, e1] {
                try d.execute(sql: "INSERT INTO diagnosis (id, patient_id, encounter_id, name, confirmed, created_at, updated_at) VALUES (?, ?, ?, '诊断', 1, 0, 0)",
                              arguments: [UUID().uuidString, patient.uuidString, enc.uuidString])
            }
        }
        let timeline = TimelineQueryStore(writer: db.writer)
        let first = try await timeline.hubPage(patientId: patient, limit: 2)
        XCTAssertEqual(first.entries.map(\.entry.refID.uuidString).first, e3.uuidString)
        XCTAssertEqual(first.entries.map(\.hub), [.encounter, nil])
        XCTAssertEqual(first.entries[0].counts, [.diagnosis: 1])
        let cursor = try XCTUnwrap(first.nextCursor)
        XCTAssertEqual(cursor.date, Date(timeIntervalSince1970: 2_500))
        let second = try await timeline.hubPage(patientId: patient, cursor: cursor, limit: 2)
        XCTAssertEqual(second.entries.map(\.entry.refID), [e2, e1])                              // 不重不漏
        XCTAssertEqual(second.entries.map { $0.counts[.diagnosis] }, [1, 1])                        // 子卡只按本页主卡批取
        XCTAssertNil(second.nextCursor)
        let empty = try await timeline.hubPage(patientId: patient, cursor: TimelineCursor(date: Date(timeIntervalSince1970: 0), refID: UUID()), limit: 2)
        XCTAssertTrue(empty.entries.isEmpty)
    }
}
