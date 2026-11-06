import XCTest

/// 帮助中心「系统诊断」入口回归（2026-11-06 业主实测：权限诊断/提醒诊断
/// 无法进入）。根因是帮助中心此前用闭包目的地推入 path 绑定的 me 栈，
/// 内部 value 路由与可见栈错位。本测试走真实入口链，防止闭包入口回归。
final class HelpCenterNavigationUITests: XCTestCase {
    func test_helpCenterDiagnosticsRowsPushTheirPages() {
        let app = UITestSupport.makeSeededApp()
        UITestSupport.openTab("我的", in: app)

        let helpEntry = app.descendants(matching: .any)["SP-25.settings.help"].firstMatch
        UITestSupport.scrollToHittable(helpEntry, in: app, maxSwipes: 15)
        XCTAssertTrue(helpEntry.waitForExistence(timeout: 5),
                      "Settings must expose the help-center entry")
        UITestSupport.tapWhenHittable(helpEntry)

        // 权限诊断
        let permissionRow = app.descendants(matching: .any)["FR22.2.permissionDiagnostics"].firstMatch
        XCTAssertTrue(permissionRow.waitForExistence(timeout: 10),
                      "Help center must render the permission diagnostics row")
        UITestSupport.tapWhenHittable(permissionRow)
        XCTAssertTrue(app.navigationBars["权限诊断"].waitForExistence(timeout: 10),
                      "Tapping 权限诊断 must push SP-43 (dead tap = closure/path mismatch)")

        // 返回帮助中心后再进提醒诊断
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let reminderRow = app.descendants(matching: .any)["FR22.3.reminderDiagnostics"].firstMatch
        XCTAssertTrue(reminderRow.waitForExistence(timeout: 10))
        UITestSupport.tapWhenHittable(reminderRow)
        XCTAssertTrue(app.navigationBars["提醒诊断"].waitForExistence(timeout: 10),
                      "Tapping 提醒诊断 must push SP-44")
    }
}
