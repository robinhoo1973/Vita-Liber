import XCTest

/// 启动门可选参考数据卡（2026-10-27 方案 B）：
/// 默认 UI 测试自动跳过该卡；强制卡用 `-uitest-boot-catalog-choice`，
/// 离线点检查必须再配 `-uitest-catalog-checker-off`（pinned root 随包后点按会真实联网）。
final class BootCatalogUITests: XCTestCase {
    private func forcedCardApp(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-gate-bypass", "-uitest-seed-finished",
                                "-uitest-boot-catalog-choice"] + extra
        app.launch()
        return app
    }

    func testOptionalCatalogCardContinuesWithoutDownloading() {
        let app = forcedCardApp()
        let card = app.otherElements["STARTUP.catalog"]
        XCTAssertTrue(card.waitForExistence(timeout: 30), "首启应显示可选参考数据卡")
        let continueButton = app.buttons["STARTUP.catalog.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30),
                      "「暂不下载，继续」后应进入主界面")
    }

    /// 卡出现不得隐式联网：checker-off 下若发生隐式检查，主按钮会快速变「重新检查」。
    func testStartupCardDoesNotCheckImplicitly() {
        let app = forcedCardApp(extra: ["-uitest-catalog-checker-off"])
        let primary = app.buttons["STARTUP.catalog.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 30))
        XCTAssertEqual(primary.label, "检查更新")
        let stillCheck = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "检查更新"), object: primary)
        XCTAssertEqual(XCTWaiter.wait(for: [stillCheck], timeout: 2), .completed,
                       "首启卡出现不得隐式发起检查")
        XCTAssertFalse(app.descendants(matching: .any)["STARTUP.catalog.progress"].exists)
    }

    /// 离线检查 → 暂不可用 → 主按钮改「重新检查」，无下载按钮；随后可继续进入。
    func testCheckerOffRechecksThenContinues() {
        let app = forcedCardApp(extra: ["-uitest-catalog-checker-off"])
        let primary = app.buttons["STARTUP.catalog.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 30))
        primary.tap()

        let recheck = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "重新检查"), object: primary)
        XCTAssertEqual(XCTWaiter.wait(for: [recheck], timeout: 5), .completed,
                       "checker 缺失时检查应落「暂不可用」并允许重新检查")
        XCTAssertFalse(app.descendants(matching: .any)["STARTUP.catalog.update"].exists)

        let continueButton = app.buttons["STARTUP.catalog.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
    }
}
