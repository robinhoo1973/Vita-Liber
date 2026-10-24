// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— 须经 macOS CI 验证
#if os(iOS) || os(macOS)
import Foundation
import Testing
import GRDB
@testable import Domain
@testable import Infrastructure

// binds: FR11.4 健康问题 store 编辑/删除/归档（2026-10-23 审查补测）
@Suite("SU-M1b-HEALTH-PROBLEM-STORE · FR11.4 健康问题编辑与删除")
struct HealthProblemStoreTests {
    private func makeStore() async throws -> (HealthProblemStore, DatabaseQueue, UUID) {
        let dbQueue = try DatabaseQueue(configuration: GRDBStore.configuration())
        let patient = UUID()
        try await dbQueue.write { db in
            try db.execute(sql: SchemaV2.ddl)
            try db.execute(sql: """
                INSERT INTO patient_profile
                  (id, display_name, relation, created_at, updated_at)
                VALUES (?, '王女士', 'self', ?, ?)
                """, arguments: [patient.uuidString,
                                 Date().timeIntervalSince1970, Date().timeIntervalSince1970])
        }
        return (HealthProblemStore(writer: dbQueue), dbQueue, patient)
    }

    @Test("update 只改年份/部位/别名，名称与类别不可变；行缺失抛 notFound")
    func updateWritesAllFieldsAndRejectsMissing() async throws {
        let (store, _, patient) = try await makeStore()
        let id = try await store.create(patientId: patient, name: "高血压", kind: "chronic",
                                        bodyRegion: "循环系统", bodySite: "心脏", now: Date())
        try await store.update(id: id, .init(bodyRegion: "循环系统", bodySite: "心脏",
                                             year: 2018, alias: "我的高血压"))
        let rows = try await store.list(patientId: patient, includeArchived: true)
        #expect(rows.count == 1)
        #expect(rows[0].name == "高血压", "2026-10-24 业主：名称是官方目录身份，不可改名")
        #expect(rows[0].year == 2018)
        #expect(rows[0].kind == "chronic", "类别不可从慢性病变更为手术史")
        #expect(rows[0].catalogId == "hypertension")
        #expect(rows[0].code == "I10")
        #expect(rows[0].alias == "我的高血压")
        #expect(rows[0].bodySite == "心脏")
        #expect(rows[0].department == "心血管内科")
        #expect(rows[0].departmentCode == "03.04")

        do {
            try await store.update(id: UUID(), .init(bodyRegion: nil, bodySite: nil,
                                                     year: nil))
            Issue.record("缺失行 update 应抛 notFound")
        } catch is HealthProblemStore.StoreError {
            // 期望路径
        }
    }

    @Test("delete 先解引用 diagnosis/observation 再删行；医疗事实行保留（BR-002）")
    func deleteNullsForeignKeysAndKeepsFacts() async throws {
        let (store, dbQueue, patient) = try await makeStore()
        let id = try await store.create(patientId: patient, name: "胆囊结石", kind: "surgery",
                                        bodyRegion: "消化系统", bodySite: "胆囊", now: Date())
        let now = Date().timeIntervalSince1970
        let diagnosisId = UUID()
        let observationId = UUID()
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO diagnosis
                  (id, patient_id, name, health_problem_id, created_at, updated_at)
                VALUES (?, ?, '胆囊结石', ?, ?, ?)
                """, arguments: [diagnosisId.uuidString, patient.uuidString,
                                 id.uuidString, now, now])
            try db.execute(sql: """
                INSERT INTO observation
                  (id, patient_id, kind, occurred_at, health_problem_id, created_at, updated_at)
                VALUES (?, ?, 'symptom', ?, ?, ?, ?)
                """, arguments: [observationId.uuidString, patient.uuidString,
                                 now, id.uuidString, now, now])
        }

        try await store.delete(id: id)

        let remaining = try await store.list(patientId: patient, includeArchived: true)
        #expect(remaining.isEmpty)
        // 医疗事实行保留，只解除关联
        try await dbQueue.read { db in
            let dx = try Row.fetchOne(db, sql: "SELECT health_problem_id FROM diagnosis WHERE id = ?",
                                      arguments: [diagnosisId.uuidString])
            let obs = try Row.fetchOne(db, sql: "SELECT health_problem_id FROM observation WHERE id = ?",
                                       arguments: [observationId.uuidString])
            #expect(dx != nil)
            #expect(obs != nil)
            #expect((dx?["health_problem_id"] as String?) == nil)
            #expect((obs?["health_problem_id"] as String?) == nil)
        }

        do {
            try await store.delete(id: UUID())
            Issue.record("缺失行 delete 应抛 notFound")
        } catch is HealthProblemStore.StoreError {
            // 期望路径
        }
    }

    @Test("归档行默认隐藏，includeArchived 可找回；取消归档恢复可见")
    func archivedRowsAreRecoverable() async throws {
        let (store, _, patient) = try await makeStore()
        let id = try await store.create(patientId: patient, name: "哮喘", now: Date())
        try await store.setArchived(id: id, archived: true)
        let hidden = try await store.list(patientId: patient)
        #expect(hidden.isEmpty)
        let all = try await store.list(patientId: patient, includeArchived: true)
        #expect(all.count == 1)
        try await store.setArchived(id: id, archived: false)
        let visible = try await store.list(patientId: patient)
        #expect(visible.count == 1)
    }
}
#endif
