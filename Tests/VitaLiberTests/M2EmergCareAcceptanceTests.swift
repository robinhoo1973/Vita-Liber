import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

// binds: SU-M2-EMERG — 急救卡三源聚合 · 逐项选择 · 未确认不入卡（BR-003）
// binds: SU-M2-CARE — SOS 两步可达（Domain 半场）+ 迁移 v4
/// F15 急救卡落库半场：选择语义（FR15.1）+ 聚合过滤（BR-003）。
/// 关怀模式 Domain 半场在 CoreKitTests（SOS 豁免/长按门槛/震颤防抖）。
@MainActor
final class M2EmergCardAcceptanceTests: XCTestCase {

    private func makeStore() async throws -> (GRDBStore, EmergencyCardStore, UUID) {
        let store = try GRDBStore.inMemory()
        let cards = EmergencyCardStore(writer: store.writer)
        let patient = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile
                  (id, display_name, relation, blood_type, created_at, updated_at)
                VALUES (?, '急救卡测试', '本人', 'A+', 0, 0)
                """, arguments: [patient.uuidString])
        }
        return (store, cards, patient)
    }

    /// FR15.1 核心语义：**数据存在 ≠ 入卡**。只有用户逐项选择的条目才入卡。
    func test_未选择不入卡_选择后才入卡() async throws {
        let (store, cards, patient) = try await makeStore()
        let allergyId = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO allergy_event
                  (id, patient_id, substance, reaction_tags, severity, created_at, updated_at)
                VALUES (?, ?, '青霉素', '皮疹', 'moderate', 0, 0)
                """, arguments: [allergyId.uuidString, patient.uuidString])
        }
        var card = try await cards.selected(patientId: patient)
        XCTAssertTrue(card.allergies.isEmpty,
                      "FR15.1：未逐项选择的过敏不得入卡（数据存在≠同意入卡）")

        try await cards.select(patientId: patient, itemId: allergyId, kind: "allergy")
        card = try await cards.selected(patientId: patient)
        XCTAssertEqual(card.allergies.count, 1)
        XCTAssertEqual(card.allergies[0].title, "青霉素")

        // 退选 = 删选择行，原始数据不动
        try await cards.deselect(patientId: patient, itemId: allergyId)
        card = try await cards.selected(patientId: patient)
        XCTAssertTrue(card.allergies.isEmpty)
        let rawCount = try await store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM allergy_event") ?? 0
        }
        XCTAssertEqual(rawCount, 1, "退选只删选择，不删数据源")
    }

    /// BR-003：聚合入口的 confirmed=false 项一律不入卡（Domain 判据半场）
    func test_未确认项不入卡_Domain判据() {
        let unconfirmed = EmergencyCardItem(id: UUID(), kind: "allergy",
                                            title: "可疑过敏", detail: "", confirmed: false)
        let confirmed = EmergencyCardItem(id: UUID(), kind: "allergy",
                                          title: "确认过敏", detail: "", confirmed: true)
        let card = EmergencyCardService.assemble(patientId: UUID(),
                                                 allergies: [unconfirmed, confirmed],
                                                 medications: [], healthProblems: [], contacts: [])
        XCTAssertEqual(card.allergies.count, 1)
        XCTAssertEqual(card.allergies[0].title, "确认过敏")
    }

    /// 急救卡空卡 → 系统医疗急救卡引导（只引导、不静默写入）
    func test_空卡引导且不写入() async throws {
        let (_, cards, patient) = try await makeStore()
        let card = try await cards.selected(patientId: patient)
        XCTAssertTrue(EmergencyCardService.medicalIDGuideNeeded(card: card),
                      "空卡必须触发系统医疗急救卡引导")
        // 系统 Medical ID 引导 = UI 跳转，本层无任何写入 API——
        // 唯一写入路径是 select()（用户显式选择），不存在「静默写入系统」的调用面
    }

    /// 血型字段随卡带出（F3 P1 字段）
    func test_血型随卡带出() async throws {
        let (_, cards, patient) = try await makeStore()
        let blood = try await cards.bloodType(patientId: patient)
        XCTAssertEqual(blood, "A+")
    }

    /// 迁移 v4：emergency_card_selection 建表且可写
    func test_迁移v4选择表可用() async throws {
        let queue = try DatabaseQueue(configuration: GRDBStore.configuration())
        _ = try GRDBStore(writer: queue)   // 全新库直接含 v4
        let patient = UUID()
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, 'x', '本人', 0, 0)
                """, arguments: [patient.uuidString])
            try db.execute(sql: """
                INSERT INTO emergency_card_selection (patient_id, item_id, item_kind, selected_at)
                VALUES (?, ?, 'allergy', 0)
                """, arguments: [patient.uuidString, UUID().uuidString])
        }
        let count = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM emergency_card_selection") ?? 0
        }
        XCTAssertEqual(count, 1)
    }
}
