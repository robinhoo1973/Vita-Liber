import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

/// TC-M1c 时间轴投影与全文搜索（test-plan §4.4）——GRDB 落库级断言
@MainActor
// binds: SU-M1c-REGRESSION / SU-M1c-EXPORT / SU-M1c-SEC — TC-M1c-01/04
final class M1cAcceptanceTests: XCTestCase {

    private func makeStore() async throws -> GRDBStore {
        let store = try GRDBStore.inMemory()
        // 种子：成员 + 就诊 + 观察 + 指标
        let member = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, '测试患者', '本人', 0, 0)
                """, arguments: [member.uuidString])
            try db.execute(sql: """
                INSERT INTO encounter (id, patient_id, date, kind, diagnosis_text, created_at, updated_at)
                VALUES (?, ?, ?, '门诊', '上呼吸道感染', ?, ?)
                """, arguments: [UUID().uuidString, member.uuidString,
                                 Date().timeIntervalSince1970 - 86400,
                                 Date().timeIntervalSince1970, Date().timeIntervalSince1970])
            try db.execute(sql: """
                INSERT INTO observation (id, patient_id, kind, occurred_at, description, created_at, updated_at)
                VALUES (?, ?, 'skin', ?, '红疹', ?, ?)
                """, arguments: [UUID().uuidString, member.uuidString,
                                 Date().timeIntervalSince1970 - 3600,
                                 Date().timeIntervalSince1970, Date().timeIntervalSince1970])
        }
        return store
    }

    /// F11 时间轴联合投影：就诊+观察同轴、时间倒序、成员隔离
    func test_时间轴联合投影与隔离() async throws {
        let store = try await makeStore()
        let timeline = TimelineQueryStore(writer: store.writer)
        let member = try await store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM patient_profile LIMIT 1") ?? ""
        }
        let page = try await timeline.entries(for: UUID(uuidString: member) ?? UUID())
        XCTAssertEqual(page.entries.count, 2)
        // 时间倒序：观察（1h 前）先于就诊（1 天前）
        XCTAssertEqual(page.entries[0].kind, .observation)
        XCTAssertEqual(page.entries[1].kind, .encounter)
        // 成员隔离：其他成员查不到
        let other = try await timeline.entries(for: UUID())
        XCTAssertTrue(other.entries.isEmpty, "BR-001：跨成员查询必须为空")
    }

    /// F13 往返一致性（一票否决）：导出 → 全新库导入 → 再导出逐字段相等
    func test_导出导入往返一致性() async throws {
        let storeA = try await makeStore()
        let exportA = ExportService(writer: storeA.writer)
        // 种子走生产路径：saveOwner 建立 owner↔本人档案关联（envelope.selfProfile
        // 的 JOIN 前提——无 local_owner 行则档案不进包）
        let persistorA = GRDBM1aPersistor(store: storeA)
        var owner = LocalOwner(displayName: "测试患者", createdAt: 0)
        let profile = PatientProfile(displayName: "测试患者", relation: "本人")
        owner.selfPatientId = profile.id
        try await persistorA.saveOwner(owner, profile: profile)
        let medsA = MedicationStore(writer: storeA.writer)
        let medId = UUID()
        try await medsA.createMedication(id: medId, patientId: profile.id, name: "阿莫西林", spec: "0.25g", unitKind: "tablet")
        try await medsA.createPlan(planId: UUID(), patientId: profile.id, medicationId: medId,
                                   schedule: .fixed(times: ["08:00", "20:00"]), status: .active,
                                   startDate: Date(), endDate: nil)

        // 补种八类业务数据（评审 S1-2：往返覆盖核心表全集）
        let obs = ObservationStore(writer: storeA.writer)
        try await obs.create(patientId: profile.id, kind: "skin", description: "红疹", selfMark: "improved")
        let allergy = AllergyStore(writer: storeA.writer)
        try await allergy.create(patientId: profile.id, substance: "青霉素", severity: "severe",
                                 reactionTags: ["rash"], note: nil)
        try await storeA.writer.write { db in
            try db.execute(sql: """
                INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, measured_at, created_at)
                VALUES (?, ?, 'blood_pressure_sys', 132, 'mmHg', 'manual', 1, ?, ?)
                """, arguments: [UUID().uuidString, profile.id.uuidString,
                                 Date().timeIntervalSince1970, Date().timeIntervalSince1970])
        }

        let envelope = try await exportA.exportJSON()
        XCTAssertEqual(envelope.plans.count, 1)
        XCTAssertEqual(envelope.observations.count, 2)  // makeStore 已种 1 条 + 本用例 1 条
        XCTAssertEqual(envelope.allergies.count, 1)
        XCTAssertEqual(envelope.metrics.count, 1)

        // 全新库导入 → 再导出 → 结构一致（往返一致性）
        let storeB = try GRDBStore.inMemory()
        let exportB = ExportService(writer: storeB.writer)
        try await exportB.importJSON(envelope)
        let envelopeB = try await exportB.exportJSON()
        XCTAssertEqual(envelopeB.plans, envelope.plans)
        XCTAssertEqual(envelopeB.consentRecords, envelope.consentRecords)
        XCTAssertEqual(envelopeB.plans[0].schedule, envelope.plans[0].schedule)
        XCTAssertEqual(envelopeB.plans[0].medicationName, "阿莫西林")
        XCTAssertEqual(envelopeB.observations, envelope.observations, "观察必须往返一致")
        XCTAssertEqual(envelopeB.allergies, envelope.allergies, "过敏必须往返一致")
        XCTAssertEqual(envelopeB.metrics, envelope.metrics, "指标必须往返一致")

        // JSON 编码/解码无损
        let data = try await exportA.encode(envelope)
        let decoded = try await exportA.decode(data)
        XCTAssertEqual(decoded.plans, envelope.plans)
    }

    /// F12 搜索：trigram 路由 + 2-gram 路由命中（FTS 双表索引同步）
    func test_搜索双路由命中() async throws {
        let store = try await makeStore()
        let search = GRDBSearchService(writer: store.writer)
        let docId = UUID()
        let member = UUID()
        try await store.writer.write { db in
            // ERR#35 纪律前置：document_file.patient_id 的外键目标先行
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, '检索患者', '本人', 0, 0)
                """, arguments: [member.uuidString])
            try db.execute(sql: """
                INSERT INTO document_file (id, patient_id, doc_type, sha256, mime_type, origin, meta_json,
                                           title, ocr_text, created_at, updated_at)
                VALUES (?, ?, 'prescription', ?, 'application/json', 'scanner', '{}', ?, ?, ?, ?)
                """, arguments: [docId.uuidString, member.uuidString, "sha-\(docId.uuidString)",
                                 "空腹血糖记录", "空腹血糖 6.2 mmol/L",
                                 Date().timeIntervalSince1970, Date().timeIntervalSince1970])
        }
        // FTS 由源表触发器同步（V3.44）——无需显式索引调用
        // ≥3 字 trigram
        let hits3 = try await search.search("空腹血糖", scope: .init(patientIds: [member]), limit: 10)
        XCTAssertTrue(hits3.contains { $0.refID == docId }, "trigram 主表必须命中")
        // 2 字 bigram
        let hits2 = try await search.search("血糖", scope: .init(patientIds: [member]), limit: 10)
        XCTAssertTrue(hits2.contains { $0.refID == docId }, "2-gram 影子表必须命中（短查询路由）")
        // 1 字 LIKE 兜底
        let hits1 = try await search.search("糖", scope: .init(patientIds: [member]), limit: 10)
        XCTAssertTrue(hits1.contains { $0.refID == docId }, "1 字 LIKE 兜底必须命中")
    }
}
