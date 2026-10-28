import XCTest

/// 启动自检页（U-批 B4，2026-10-28）：
/// - 通用 `-uitest-*` 默认不渲染自检页（O21；既有用例行为不变）；
/// - `-uitest-selfcheck-hold` 冻结被动 hold 与卡片 autoEnter，页面保持可见；
/// - `-uitest-selfcheck-failure=<case>` prepare 桩注入确定性失败态。
final class BootSelfCheckUITests: XCTestCase {
    private func holdApp(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-gate-bypass", "-uitest-seed-finished",
                                "-uitest-selfcheck-hold"] + extra
        app.launch()
        return app
    }

    /// 显式 hold：四行俱在、行④检查按钮可用、且不得自动进入主界面。
    func testHoldKeepsSelfCheckRowsVisible() {
        let app = holdApp()
        XCTAssertTrue(app.otherElements["STARTUP.selfcheck"].waitForExistence(timeout: 30),
                      "hold 下自检清单应常驻")
        for id in ["dbFile", "schema", "catalog", "updates"] {
            XCTAssertTrue(app.descendants(matching: .any)["STARTUP.selfcheck.\(id)"].exists,
                          "缺自检行 \(id)")
        }
        XCTAssertTrue(app.buttons["STARTUP.selfcheck.updates.check"].exists,
                      "行④检查按钮应在位")
        XCTAssertFalse(app.tabBars.firstMatch.waitForExistence(timeout: 3),
                       "hold 下不得自动放行主界面")
    }

    /// O21：不带 hold 的通用 `-uitest-*` 启动应直达主界面（自检页不阻塞）。
    func testDefaultUITestSkipsSelfCheckPage() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-gate-bypass", "-uitest-seed-finished"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30),
                      "默认 -uitest- 应跳过自检页直达主界面")
    }

    /// 行④点「检查」+ checker 缺失 → 聚合落 .unavailable → 行态「未通过」。
    func testRowFourCheckWithCheckerOff() {
        let app = holdApp(extra: ["-uitest-catalog-checker-off"])
        let row = app.otherElements["STARTUP.selfcheck.updates"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        let button = app.buttons["STARTUP.selfcheck.updates.check"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let failed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "未通过"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 10), .completed,
                       "checker 缺失时行④应落「未通过」态")
    }

    /// 失败桩：失败卡 + 重试按钮 + 自检行仍在（失败路径仍展示事实）。
    func testFailureHookShowsFailureCard() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-gate-bypass", "-uitest-seed-finished",
                                "-uitest-selfcheck-failure=tooNew"]
        app.launch()
        XCTAssertTrue(app.otherElements["STARTUP.failure"].waitForExistence(timeout: 30),
                      "失败桩应展示失败卡")
        XCTAssertTrue(app.buttons["STARTUP.initialization.retry"].exists,
                      "失败卡应有重试按钮")
        XCTAssertTrue(app.otherElements["STARTUP.selfcheck"].exists,
                      "失败路径自检行仍应在屏")
    }
}
