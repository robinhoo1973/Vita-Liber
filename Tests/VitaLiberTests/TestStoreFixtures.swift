import Foundation
import GRDB
import Domain
import Infrastructure

/// 测试仓夹具单一出口（审查修复 2026-09-18 收敛）：
/// 十余套件的 makeStore 各自逐字重复「建 patient_profile 行 / 建本人绑定 /
/// 建药品行」种子——语义变更只改一份时其余仍在测旧种子，与生产 API 漂移。
/// 收敛为 GRDBStore 扩展单一出口；调用点只改种子来源、参数原样保留。
/// 时区日历单一出口（shanghaiCalendar）在 HealthImportTestSupport.swift。

extension GRDBStore {
    /// 单成员夹具：patient_profile 一行（document_file / encounter 等外键目标，ERR#35 纪律前置）。
    static func inMemoryWithPatient(_ name: String = "A", relation: String = "other",
                                    bloodType: String? = nil) async throws -> (GRDBStore, UUID) {
        let store = try GRDBStore.inMemory()
        let patient = try await store.insertPatient(name, relation: relation, bloodType: bloodType)
        return (store, patient)
    }

    /// 本人绑定夹具：patient_profile(relation=self) + local_owner 两行
    /// （HealthKit / 趋势导出 envelope 的 selfProfile JOIN 前提）。
    static func inMemoryWithOwner(_ name: String = "Owner", relation: String = "self") async throws -> (GRDBStore, UUID) {
        let store = try GRDBStore.inMemory()
        let patient = try await store.insertPatient(name, relation: relation)
        try await store.insertLocalOwner(name, selfPatient: patient)
        return (store, patient)
    }

    /// 药品夹具：patient_profile + medication 两行（stock_lot 外键目标），附带 MedicationStore。
    static func inMemoryWithMedication(patientName: String, relation: String = "本人",
                                       medName: String, spec: String,
                                       unitKind: String = "tablet") async throws -> (GRDBStore, MedicationStore, UUID, UUID) {
        let (store, patient) = try await inMemoryWithPatient(patientName, relation: relation)
        let med = try await store.insertMedication(patient: patient, name: medName, spec: spec, unitKind: unitKind)
        return (store, MedicationStore(writer: store.writer), patient, med)
    }

    func insertPatient(_ name: String, relation: String, bloodType: String? = nil) async throws -> UUID {
        let patient = UUID()
        try await writer.write { db in
            if let bloodType {
                try db.execute(sql: """
                    INSERT INTO patient_profile (id, display_name, relation, blood_type, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 0, 0)
                    """, arguments: [patient.uuidString, name, relation, bloodType])
            } else {
                try db.execute(sql: """
                    INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                    VALUES (?, ?, ?, 0, 0)
                    """, arguments: [patient.uuidString, name, relation])
            }
        }
        return patient
    }

    func insertLocalOwner(_ name: String, selfPatient: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO local_owner (id, display_name, self_patient_id, created_at)
                VALUES (?, ?, ?, 0)
                """, arguments: [UUID().uuidString, name, selfPatient.uuidString])
        }
    }

    func insertMedication(patient: UUID, name: String, spec: String,
                          unitKind: String = "tablet") async throws -> UUID {
        let med = UUID()
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO medication (id, patient_id, generic_name, spec, unit_kind, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 0, 0)
                """, arguments: [med.uuidString, patient.uuidString, name, spec, unitKind])
        }
        return med
    }
}

/// 表行数向量（事务回滚 / 幂等断言共用）：单次读事务内按表取 COUNT。
func tableCounts(_ db: GRDBStore, _ tables: [String]) async throws -> [Int] {
    try await db.writer.read { db in
        try tables.map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1 }
    }
}
