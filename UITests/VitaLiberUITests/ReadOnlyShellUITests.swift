import XCTest

/// 只读降级壳（B3 证据，2026-10-28）：DEBUG 钩子 `-uitest-boot-readonly`
/// 合成 tooNew 失败并确保测试库存在 → 失败卡出现「只读查看」→ 进入只读壳
/// （横幅 + 急救卡只读页 + 无主界面 Tab）。
final class ReadOnlyShellUITests: XCTestCase {
    func testReadOnlyShellFromFailureCard() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-gate-bypass", "-uitest-seed-finished",
                                "-uitest-boot-readonly"]
        app.launch()

        let enter = app.buttons["STARTUP.readonly.enter"]
        XCTAssertTrue(enter.waitForExistence(timeout: 30), "失败卡应出现「只读查看」")
        enter.tap()

        XCTAssertTrue(app.otherElements["READONLY.root"].waitForExistence(timeout: 10),
                      "应进入只读壳")
        XCTAssertTrue(app.descendants(matching: .any)["READONLY.banner"].exists,
                      "只读横幅必须常驻")
        XCTAssertTrue(app.descendants(matching: .any)["READONLY.emergency"].exists,
                      "急救卡只读页应可读")
        XCTAssertFalse(app.tabBars.firstMatch.waitForExistence(timeout: 3),
                       "只读壳不得出现主界面 Tab（无会话）")
    }
}
