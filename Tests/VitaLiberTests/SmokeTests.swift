import XCTest
@testable import VitaLiber

// binds: SU-M0-SMOKE — TC-M0-09 启动冒烟
final class SmokeTests: XCTestCase {
    func test_SU_M0_SMOKE_MainModule五枚举完整() { XCTAssertEqual(MainModule.allCases.count, 5) }

    /// 评审 S2-1 修正：模块键必须与 ui-ux §9 规范一致（home/records/reminders/ai/me），
    /// 且每个模块都有图标与本地化标题——枚举不再兼职中文 UI 串。
    func test_MainModule_键与规范一致() {
        XCTAssertEqual(MainModule.allCases.map(\.rawValue), ["home", "records", "reminders", "ai", "me"])
    }
}
