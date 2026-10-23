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
        let (store, patient) = try await GRDBStore.inMemoryWithPatient("急救卡测试", relation: "本人", bloodType: "A+")
        return (store, EmergencyCardStore(writer: store.writer), patient)
    }

    /// 2026-10-24 业主语义（v44）：档案已确认条目默认入卡，显式退选才排除。
    /// 原名：test_未选择不入卡_选择后才入卡
    func test_defaultIncluded_deselectExcluded() async throws {
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
        XCTAssertEqual(card.allergies.count, 1,
                       "档案已有过敏必须默认出现在急救卡（v44 业主裁决）")
        XCTAssertEqual(card.allergies[0].title, "青霉素")

        // 显式退选只记 deselected=1，原始数据不动
        try await cards.deselect(patientId: patient, itemId: allergyId)
        card = try await cards.selected(patientId: patient)
        XCTAssertTrue(card.allergies.isEmpty)
        let rawCount = try await store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM allergy_event") ?? 0
        }
        XCTAssertEqual(rawCount, 1, "退选只改选择记录，不删数据源")

        // 重新纳入恢复入卡
        try await cards.select(patientId: patient, itemId: allergyId, kind: "allergy")
        card = try await cards.selected(patientId: patient)
        XCTAssertEqual(card.allergies.count, 1)
    }

    /// 业主 2026-10-24：慢性病/手术史与紧急联系人同样默认入卡。
    func test_healthProblemsAndEmergencyContactsIncludedByDefault() async throws {
        let (store, cards, patient) = try await makeStore()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO health_problem
                  (id, patient_id, name, kind, archived, created_at, updated_at)
                VALUES (?, ?, '高血压', 'chronic', 0, 0, 0)
                """, arguments: [UUID().uuidString, patient.uuidString])
            try db.execute(sql: """
                INSERT INTO health_problem
                  (id, patient_id, name, kind, archived, created_at, updated_at)
                VALUES (?, ?, '胆囊切除术', 'surgery', 0, 0, 0)
                """, arguments: [UUID().uuidString, patient.uuidString])
            try db.execute(sql: """
                INSERT INTO contact
                  (id, patient_id, name, relation, phone, is_emergency, created_at, updated_at)
                VALUES (?, ?, '李四', '配偶', '13800000000', 1, 0, 0)
                """, arguments: [UUID().uuidString, patient.uuidString])
        }
        let card = try await cards.selected(patientId: patient)
        XCTAssertEqual(Set(card.healthProblems.map(\.title)), ["高血压", "胆囊切除术"])
        XCTAssertEqual(card.contacts.count, 1)
        XCTAssertEqual(card.contacts[0].title, "李四")
    }

    /// BR-003：聚合入口的 confirmed=false 项一律不入卡（Domain 判据半场）
    /// 原名：test_未确认项不入卡_Domain判据
    func test_unconfirmedItemsExcluded_domainCriterion() {
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
    /// 原名：test_空卡引导且不写入
    func test_emptyCardGuidesAndDoesNotWrite() async throws {
        let (_, cards, patient) = try await makeStore()
        let card = try await cards.selected(patientId: patient)
        XCTAssertTrue(EmergencyCardService.medicalIDGuideNeeded(card: card),
                      "空卡必须触发系统医疗急救卡引导")
        // 系统 Medical ID 引导 = UI 跳转，本层无任何写入 API——
        // 唯一写入路径是 select()（用户显式选择），不存在「静默写入系统」的调用面
    }

    /// 血型字段随卡带出（F3 P1 字段）
    /// 原名：test_血型随卡带出
    func test_bloodTypeCarriedIntoCard() async throws {
        let (_, cards, patient) = try await makeStore()
        let blood = try await cards.bloodType(patientId: patient)
        XCTAssertEqual(blood, "A+")
    }

    /// 迁移 v4：emergency_card_selection 建表且可写
    /// 原名：test_迁移v4选择表可用
    func test_migrationV4SelectionTableUsable() async throws {
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
