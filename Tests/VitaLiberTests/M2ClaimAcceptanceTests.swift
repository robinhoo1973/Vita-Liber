import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

// binds: SU-M2-CARE — FR13.7 报销票据落库（纯事实汇总，不做报销建议）
@MainActor
final class M2ClaimAcceptanceTests: XCTestCase {

    private func makeStore() async throws -> (GRDBStore, ClaimStore, UUID) {
        let store = try GRDBStore.inMemory()
        let claims = ClaimStore(writer: store.writer)
        let patient = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, '报销测试', '本人', 0, 0)
                """, arguments: [patient.uuidString])
        }
        return (store, claims, patient)
    }

    func test_录入与汇总纯事实() async throws {
        let (_, claims, patient) = try await makeStore()
        try await claims.create(patientId: patient, itemType: "invoice", amount: 128.5,
                                date: Date(), merchant: "市一医院", summary: "门诊挂号费")
        try await claims.create(patientId: patient, itemType: "fee", amount: 45.0,
                                date: Date(), merchant: "市一医院", summary: "检查费")

        let totals = try await claims.totals(patientId: patient)
        XCTAssertEqual(totals.itemCount, 2)
        XCTAssertEqual(totals.totalAmount, 173.5, accuracy: 0.001)
        XCTAssertEqual(totals.currency, "CNY")
        // 展示语句已移入视图层（L10n 单出口）：断言组装结果原样携带数量与金额
        let statement = L10n.claimTotals(totals.itemCount, "173.50", totals.currency)
        XCTAssertTrue(statement.contains("2"))
        XCTAssertTrue(statement.contains("173.50"))
    }

    /// FR13.7 边界：汇总只求和——不评判「哪些可报」、不生成报销建议
    func test_汇总语句无报销建议词() async throws {
        let (_, claims, patient) = try await makeStore()
        try await claims.create(patientId: patient, itemType: "receipt", amount: 10,
                                date: Date(), merchant: "药店", summary: "")
        let totals = try await claims.totals(patientId: patient)
        // FR13.7 纯事实边界现在由两层共同保证：Totals 结构只有数值+币种字段，
        // 展示模板（L10n）不得加入任何报销判断词——此处直接锁模板本身。
        let statement = L10n.claimTotals(totals.itemCount, "10.00", totals.currency)
        for banned in ["可报销", "不可报销", "建议", "应该"] {
            XCTAssertFalse(statement.contains(banned),
                           "汇总出现报销判断词「\(banned)」——FR13.7 纯事实边界")
        }
    }

    func test_成员隔离() async throws {
        let (_, claims, patient) = try await makeStore()
        try await claims.create(patientId: patient, itemType: "invoice", amount: 5,
                                date: Date(), merchant: "x", summary: "")
        let others = try await claims.list(patientId: UUID())
        XCTAssertTrue(others.isEmpty, "BR-001：跨成员票据必须隔离")
    }
}
