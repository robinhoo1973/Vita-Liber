import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

// binds: SU-M1a-GOLDEN — FR3.7 添加家人落库（成员 = PatientProfile，本人 + 家人共存）
@MainActor
final class MemberAcceptanceTests: XCTestCase {

    /// saveOwner（本人）→ saveMember（家人）→ members() 两张档案并存且字段往返
    /// 原名：test_成员落库与往返
    func test_memberPersistAndRoundTrip() async throws {
        let store = try GRDBStore.inMemory()
        let persistor = GRDBPatientPersistor(store: store)

        let now = Date().timeIntervalSince1970
        let owner = LocalOwner(displayName: "本人", createdAt: now)
        let selfProfile = PatientProfile(displayName: "本人", relation: "本人",
                                         createdAt: now, updatedAt: now)
        try await persistor.saveOwner(owner, profile: selfProfile)

        let child = PatientProfile(displayName: "小王", relation: "子女",
                                   birthDate: "2012-05", createdAt: now, updatedAt: now)
        try await persistor.saveMember(child)

        let members = try await persistor.members()
        XCTAssertEqual(members.count, 2, "本人 + 家人两张档案并存（FR3.7）")
        let added = try XCTUnwrap(members.first { $0.displayName == "小王" })
        XCTAssertEqual(added.relation, "子女")
        XCTAssertEqual(added.birthDate, "2012-05")
    }

    func test_voiceStructuredWritesDedupeBySubstanceAndPhone() async throws {
        let store = try GRDBStore.inMemory()
        let persistor = GRDBPatientPersistor(store: store)
        let now = Date().timeIntervalSince1970
        let owner = LocalOwner(displayName: "本人", createdAt: now)
        let profile = PatientProfile(displayName: "本人", relation: "本人",
                                     createdAt: now, updatedAt: now)
        try await persistor.saveOwner(owner, profile: profile)

        try await persistor.saveVoiceAllergy(patientId: profile.id, substance: "青霉素",
                                             severity: "轻", reactionTags: ["皮疹"], note: "青霉素过敏")
        try await persistor.saveVoiceAllergy(patientId: profile.id, substance: "青霉素",
                                             severity: "重", reactionTags: ["呼吸困难"], note: "青霉素过敏")
        try await persistor.saveVoiceHealthProblem(patientId: profile.id, name: "高血压")
        try await persistor.saveVoiceHealthProblem(patientId: profile.id, name: "高血压")
        try await persistor.saveVoiceEmergencyContact(
            patientId: profile.id,
            contact: EmergencyContactDraft(name: "张三", relation: "子女", phone: "13800138000"))
        try await persistor.saveVoiceMedication(patientId: profile.id, name: "二甲双胍")
        try await persistor.saveVoiceMedication(patientId: profile.id, name: "二甲双胍")

        let counts = try await store.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM allergy_event") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_problem") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM contact") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM medication_plan WHERE status = 'active'") ?? 0)
        }
        XCTAssertEqual(counts.0, 1, "同过敏原重复确认只更新，不新增")
        XCTAssertEqual(counts.1, 1, "同既往史不重复建问题")
        XCTAssertEqual(counts.2, 1, "同手机号紧急联系人不重复")
        XCTAssertEqual(counts.3, 1, "同药名不重复建活动计划")
    }

    /// 成员配额：Domain 判定与落库计数一致（4 人内不弹、第 5 人弹）
    /// 原名：test_配额边界与落库一致
    func test_quotaBoundaryMatchesPersistedState() async throws {
        let store = try GRDBStore.inMemory()
        let persistor = GRDBPatientPersistor(store: store)
        let now = Date().timeIntervalSince1970
        let owner = LocalOwner(displayName: "本人", createdAt: now)
        try await persistor.saveOwner(owner, profile: PatientProfile(
            displayName: "本人", relation: "本人", createdAt: now, updatedAt: now))
        for i in 1...3 {
            try await persistor.saveMember(PatientProfile(
                displayName: "成员\(i)", relation: "子女", createdAt: now, updatedAt: now))
        }
        let count = try await persistor.members().count
        XCTAssertEqual(count, 4)
        XCTAssertFalse(PaywallRules.addingMemberWouldExceed(currentCount: 3),
                       "已有 3 人时加第 4 个不弹墙（免费档 ≥4 人）")
        XCTAssertTrue(PaywallRules.addingMemberWouldExceed(currentCount: 4),
                      "已有 4 人时加第 5 个越过配额（memberQuotaReached 触发点）")
    }
}
