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
    func test_成员落库与往返() async throws {
        let store = try GRDBStore.inMemory()
        let persistor = GRDBM1aPersistor(store: store)

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

    /// 成员配额：Domain 判定与落库计数一致（4 人内不弹、第 5 人弹）
    func test_配额边界与落库一致() async throws {
        let store = try GRDBStore.inMemory()
        let persistor = GRDBM1aPersistor(store: store)
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
