import XCTest
import Foundation
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

/// TC-M1a-03/05 的 App 层半场（test-plan §4.2）：
/// 锁定阶梯与跨重启保持、L1 三卡 ConsentRecord 落库、BR-003。
/// 评审修正：经 GRDBM1aPersistor 走真实 §4.3 表——「本人关联 patient_profile」
/// 从 ID 断言升级为落库断言，闭合假绿。
@MainActor
final class M1aAcceptanceTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "M1aAcceptanceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func makeApp(defaults: UserDefaults, fixture: Bool = false) throws -> AppState {
        let container = try AppContainer.preview()
        return AppState(persistor: container.persistor,
                        capture: FakeOcrProvider(fixture: fixture),
                        defaults: defaults, launchArgs: [])
    }

    /// FR1.3：错误 PIN 5 次锁定；锁定跨 App 重启（同存储重建）保持。
    /// 阶梯唯一实现 = Domain PinLockStateMachine（App 层只镜像）。
    func test_错误PIN五次锁定且跨重启保持() async throws {
        let defaults = freshDefaults()
        let app = try makeApp(defaults: defaults)
        await app.bootstrap()
        app.setupPin("135790")

        for _ in 0..<5 {
            let ok = await app.verifyPin("000000")
            XCTAssertFalse(ok)
        }
        XCTAssertTrue(app.isLocked)

        // 重启（同 defaults + 同 persistor 重建）→ 锁定保持
        let app2 = try makeApp(defaults: defaults)
        await app2.bootstrap()
        XCTAssertTrue(app2.isLocked, "锁定必须跨重启保持（FR1.3 用例）")

        // 锁定期间正确 PIN 也不放行
        let ok = await app2.verifyPin("135790")
        XCTAssertFalse(ok)
    }

    /// 成功验证复位计数与阶梯（评审 A3：App 副本曾不清 lockStage，
    /// 阶梯永久爬升至 5min 封顶——Domain recordSuccess 必须真实接线）
    func test_成功验证复位计数与阶梯() async throws {
        let defaults = freshDefaults()
        let app = try makeApp(defaults: defaults)
        await app.bootstrap()
        app.setupPin("135790")
        for _ in 0..<4 {
            let ok = await app.verifyPin("111111")
            XCTAssertFalse(ok)
        }
        let ok = await app.verifyPin("135790")
        XCTAssertTrue(ok)
        XCTAssertFalse(app.isLocked)
        // 复位后再错 5 次 → 仍从第一档 30s 起锁（阶梯未爬升）
        for _ in 0..<5 {
            _ = await app.verifyPin("222222")
        }
        XCTAssertTrue(app.isLocked)
        XCTAssertEqual(app.remainingLockSeconds, 30)
    }

    /// TC-M1a-05：L1 三卡逐卡确认 → 每条卡生成对应 ConsentRecord 并落 consent_record 表
    func test_三卡确认写入ConsentRecord且落库() async throws {
        let defaults = freshDefaults()
        let container = try AppContainer.preview()
        let app = AppState(persistor: container.persistor, capture: FakeOcrProvider(fixture: false),
                           defaults: defaults, launchArgs: [])
        await app.bootstrap()
        XCTAssertEqual(app.disclosureCards.count, 3)
        app.advanceDisclosure()
        app.advanceDisclosure()
        app.advanceDisclosure()
        XCTAssertEqual(app.consentRecords.count, 3)
        XCTAssertEqual(Set(app.consentRecords.map(\.key)).count, 3)   // 三卡三键不重复

        // 落库断言（评审修正：不再是 UserDefaults 写入）；异步持久化任务轮询等落库
        var stored: [ConsentRecord] = []
        for _ in 0..<20 {
            stored = try await container.persistor.loadConsents()
            if stored.count == 3 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(stored.count, 3, "ConsentRecord 必须真实写入 consent_record 表")

        // 重启不重复落库（评审修正：杀进程重走三卡去重）
        let app2 = AppState(persistor: container.persistor, capture: FakeOcrProvider(fixture: false),
                            defaults: defaults, launchArgs: [])
        await app2.bootstrap()
        XCTAssertEqual(app2.consentRecords.count, 3)
        app2.advanceDisclosure()
        XCTAssertEqual(app2.consentRecords.count, 3, "已确认的卡不得重复落 ConsentRecord")
    }

    /// LocalOwner 建立 → patient_profile 出现「本人」关联（评审修正：落库断言闭合假绿）
    func test_建档后本人关联落库() async throws {
        let defaults = freshDefaults()
        let container = try AppContainer.preview()
        let app = AppState(persistor: container.persistor, capture: FakeOcrProvider(fixture: false),
                           defaults: defaults, launchArgs: [])
        await app.bootstrap()
        app.createOwner(name: "王女士")
        // 等待异步持久化落库
        for _ in 0..<20 {
            let count = try await container.store.writer.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM patient_profile") ?? 0
            }
            if count == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let profileCount = try await container.store.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM patient_profile") ?? 0
        }
        let ownerCount = try await container.store.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM local_owner") ?? 0
        }
        XCTAssertEqual(profileCount, 1, "patient_profile 必须出现「本人」档案行")
        XCTAssertEqual(ownerCount, 1, "local_owner 必须出现所有者行")
    }

    /// BR-003：字段未全部确认前 commit 不生效，全部确认后才入时间轴
    func test_未全部确认不得入时间轴_BR003() async throws {
        let defaults = freshDefaults()
        let app = try makeApp(defaults: defaults, fixture: true)
        await app.bootstrap()
        app.createOwner(name: "王女士")
        app.captureSample()
        // 等异步拍摄完成
        for _ in 0..<20 {
            if app.activeSet != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let set = try XCTUnwrap(app.activeSet)
        app.confirmField(id: set.fields[0].id)
        app.commitToTimeline()                       // 只确认一个字段 → 不得入轴
        XCTAssertTrue(app.timeline.isEmpty, "BR-003：未全部确认不得进入时间轴正式区")
        app.confirmField(id: set.fields[1].id)
        app.confirmField(id: set.fields[2].id)
        app.commitToTimeline()
        XCTAssertEqual(app.timeline.count, 1)
    }

    /// 修订历史：确认态字段修改 → 旧值入史（FR6.4 退出准则的 U 半场）
    func test_确认后修改留修订历史() async throws {
        let defaults = freshDefaults()
        let app = try makeApp(defaults: defaults, fixture: true)
        await app.bootstrap()
        app.createOwner(name: "王女士")
        app.captureSample()
        for _ in 0..<20 {
            if app.activeSet != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let set = try XCTUnwrap(app.activeSet)
        let dosage = set.fields.first { $0.key == "dosage" }!
        app.confirmField(id: dosage.id)
        app.reviseField(id: dosage.id, to: "每日两次 每次一粒")
        app.confirmField(id: set.fields.first { $0.key == "drug_name" }!.id)
        app.confirmField(id: set.fields.first { $0.key == "title" }!.id)
        app.commitToTimeline()
        XCTAssertEqual(app.timeline.count, 1)
        XCTAssertFalse(app.timeline[0].revisionHistory.isEmpty, "修订历史必须随文档入轴")
        XCTAssertTrue(app.timeline[0].revisionHistory.contains("每日三次 每次一粒"))
    }
}
