import XCTest
import Foundation
@testable import VitaLiber
import Domain

/// TC-M1a-03/05 的 App 层半场（test-plan §4.2）：
/// 锁定阶梯与跨重启保持、L1 三卡 ConsentRecord 落库。
@MainActor
final class M1aAcceptanceTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "M1aAcceptanceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// FR1.3：错误 PIN 5 次锁定；锁定跨 App 重启（同存储重建 AppState）保持。
    func test_错误PIN五次锁定且跨重启保持() throws {
        let defaults = freshDefaults()
        let app = AppState(defaults: defaults, launchArgs: [])
        app.setupPin("135790")

        // 5 次错误 → 锁定 30s（§5.32 阶梯第一档）
        for _ in 0..<5 {
            XCTAssertFalse(app.verifyPin("000000"))
        }
        XCTAssertTrue(app.isLocked)

        // 重启（同 defaults 重建）→ 锁定保持
        let app2 = AppState(defaults: defaults, launchArgs: [])
        XCTAssertTrue(app2.isLocked, "锁定必须跨重启保持（FR1.3 用例）")

        // 锁定期间正确 PIN 也不放行
        XCTAssertFalse(app2.verifyPin("135790"))
    }

    /// 成功验证复位计数（防攻击者刷爆计数造成 DoS）
    func test_成功验证复位计数() throws {
        let defaults = freshDefaults()
        let app = AppState(defaults: defaults, launchArgs: [])
        app.setupPin("135790")
        for _ in 0..<4 { XCTAssertFalse(app.verifyPin("111111")) }
        XCTAssertTrue(app.verifyPin("135790"))
        XCTAssertFalse(app.isLocked)
    }

    /// TC-M1a-05：L1 三卡逐卡确认 → 每条卡生成对应 ConsentRecord
    func test_三卡确认写入ConsentRecord() throws {
        let defaults = freshDefaults()
        let app = AppState(defaults: defaults, launchArgs: [])
        XCTAssertEqual(app.disclosureCards.count, 3)
        app.advanceDisclosure()
        app.advanceDisclosure()
        app.advanceDisclosure()
        XCTAssertEqual(app.consentRecords.count, 3)
        XCTAssertEqual(Set(app.consentRecords.map(\.key)).count, 3)   // 三卡三键不重复
        // 落库持久化（FR20.5）
        let app2 = AppState(defaults: defaults, launchArgs: [])
        XCTAssertEqual(app2.consentRecords.count, 3)
    }

    /// BR-003：字段未全部确认前 commit 不生效，activeSet 不可入轴
    func test_未全部确认不得入时间轴_BR003() throws {
        let defaults = freshDefaults()
        let app = AppState(defaults: defaults, launchArgs: ["-uitest-camera-fixture"])
        app.createOwner(name: "王女士")
        app.captureSample()
        let set = try XCTUnwrap(app.activeSet)
        app.confirmField(id: set.fields[0].id)
        app.commitToTimeline()                       // 只确认一个字段 → 不得入轴
        XCTAssertTrue(app.timeline.isEmpty, "BR-003：未全部确认不得进入时间轴正式区")
        app.confirmField(id: set.fields[1].id)
        app.confirmField(id: set.fields[2].id)
        app.commitToTimeline()
        XCTAssertEqual(app.timeline.count, 1)
    }
}
