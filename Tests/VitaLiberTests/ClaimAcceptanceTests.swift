import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

// binds: SU-M2-CARE — FR13.7 报销票据落库（纯事实汇总，不做报销建议）
@MainActor
final class ClaimAcceptanceTests: XCTestCase {

    private func makeStore() async throws -> (GRDBStore, ClaimStore, UUID) {
        let (store, patient) = try await GRDBStore.inMemoryWithPatient("报销测试", relation: "本人")
        return (store, ClaimStore(writer: store.writer), patient)
    }

    /// 原名：test_录入与汇总纯事实
    func test_entryAndSummaryPureFacts() async throws {
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
        let statement = L10n.claimTotals(totals.itemCount, "173.50")
        XCTAssertTrue(statement.contains("2"))
        XCTAssertTrue(statement.contains("173.50"))
    }

    /// FR13.7 边界：汇总只求和——不评判「哪些可报」、不生成报销建议
    /// 原名：test_汇总语句无报销建议词
    func test_summarySentencesAvoidReimbursementAdviceWords() async throws {
        let (_, claims, patient) = try await makeStore()
        try await claims.create(patientId: patient, itemType: "receipt", amount: 10,
                                date: Date(), merchant: "药店", summary: "")
        let totals = try await claims.totals(patientId: patient)
        // FR13.7 纯事实边界现在由两层共同保证：Totals 结构只有数值+币种字段，
        // 展示模板（L10n）不得加入任何报销判断词——此处直接锁模板本身。
        let statement = L10n.claimTotals(totals.itemCount, "10.00")
        for banned in ["可报销", "不可报销", "建议", "应该"] {
            XCTAssertFalse(statement.contains(banned),
                           "汇总出现报销判断词「\(banned)」——FR13.7 纯事实边界")
        }
    }

    /// 原名：test_成员隔离
    func test_memberIsolation() async throws {
        let (_, claims, patient) = try await makeStore()
        try await claims.create(patientId: patient, itemType: "invoice", amount: 5,
                                date: Date(), merchant: "x", summary: "")
        let others = try await claims.list(patientId: UUID())
        XCTAssertTrue(others.isEmpty, "BR-001：跨成员票据必须隔离")
    }
}
