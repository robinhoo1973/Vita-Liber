import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

// binds: SU-M2-CARE — FR4.5/FR4.6 疫苗记录落库（来源/确认状态 + 剂次序号）
/// 疫苗记录仓储半场：C/D 级确认语义、剂次序号只作如实提示（FR4.6 边界）。
@MainActor
final class M2ImmunizationAcceptanceTests: XCTestCase {

    private func makeStore() async throws -> (GRDBStore, ImmunizationStore, UUID) {
        let store = try GRDBStore.inMemory()
        let immunizations = ImmunizationStore(writer: store.writer)
        let patient = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, '疫苗测试', '本人', 0, 0)
                """, arguments: [patient.uuidString])
        }
        return (store, immunizations, patient)
    }

    /// FR4.5：手动录入 = C 级已确认；OCR 派生 = D 级待确认（BR-003）
    func test_来源与确认状态() async throws {
        let (_, immunizations, patient) = try await makeStore()
        try await immunizations.create(patientId: patient, vaccineName: "流感疫苗",
                                       doseNumber: 1, administeredAt: Date(),
                                       provider: "社区卫生中心", lotNumber: "L2026A")
        try await immunizations.create(patientId: patient, vaccineName: "肺炎球菌疫苗",
                                       doseNumber: 1, administeredAt: Date(),
                                       confirmed: false, source: "ocr")

        let records = try await immunizations.list(patientId: patient)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[0].confirmed == true || records[1].confirmed == true)
        let ocr = records.first { !$0.confirmed }
        XCTAssertNotNil(ocr, "OCR 派生记录必须以待确认态入库（BR-003）")
        XCTAssertEqual(ocr?.source, "ocr")
    }

    /// FR4.6 边界：剂次序号是如实提示，不内置「该打什么」判定
    func test_下一剂次序号只作如实提示() async throws {
        let (_, immunizations, patient) = try await makeStore()
        try await immunizations.create(patientId: patient, vaccineName: "乙肝疫苗",
                                       doseNumber: 1, administeredAt: Date())
        try await immunizations.create(patientId: patient, vaccineName: "乙肝疫苗",
                                       doseNumber: 2, administeredAt: Date())
        let next = try await immunizations.nextDoseNumber(patientId: patient, vaccineName: "乙肝疫苗")
        XCTAssertEqual(next, 3)
        let other = try await immunizations.nextDoseNumber(patientId: patient, vaccineName: "流感疫苗")
        XCTAssertEqual(other, 1)
    }

    /// 成员隔离（BR-001）
    func test_成员隔离() async throws {
        let (_, immunizations, patient) = try await makeStore()
        try await immunizations.create(patientId: patient, vaccineName: "流感疫苗",
                                       doseNumber: 1, administeredAt: Date())
        let others = try await immunizations.list(patientId: UUID())
        XCTAssertTrue(others.isEmpty, "跨成员疫苗记录必须隔离")
    }
}
