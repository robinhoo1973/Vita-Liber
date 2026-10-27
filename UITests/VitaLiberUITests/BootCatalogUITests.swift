import XCTest

/// 启动门可选参考数据卡（2026-10-27 审查 P3）：默认 UI 测试自动跳过该卡，
/// 本用例用 -uitest-boot-catalog-choice 强制呈现，验证「不下载也能进入」。
final class BootCatalogUITests: XCTestCase {
    func testOptionalCatalogCardContinuesWithoutDownloading() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-gate-bypass", "-uitest-seed-finished",
                                "-uitest-boot-catalog-choice"]
        app.launch()
        let card = app.otherElements["STARTUP.catalog"]
        XCTAssertTrue(card.waitForExistence(timeout: 30), "首启应显示可选参考数据卡")
        let continueButton = app.buttons["STARTUP.catalog.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30),
                      "「稍后再说」后应进入主界面")
    }
}
