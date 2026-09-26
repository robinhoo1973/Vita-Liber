import XCTest

/// Shared presentation-test scaffolding（2026-09-26 审查修复：三份 launch-args 样板 +
/// 两份 swipe-until-hittable 循环此前各自复制、容差漂移）。
/// 自由函数形态（非 XCTestCase 子类），避免被测试发现器当成测试类。
enum UITestSupport {
    /// 重置态种子 App（-uitest-reset 清库 + 建档流程已完成 + 门禁绕过）。
    static func makeSeededApp(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-uitest-gate-bypass", "-uitest-seed-finished"]
        if reset { args.insert("-uitest-reset", at: 0) }
        app.launchArguments = args
        app.launch()
        return app
    }

    /// 等 Tab 栏出现并切到指定 Tab（zh-Hans 界面字面量）。
    static func openTab(_ name: String, in app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "Tab bar did not appear")
        tabBar.buttons[name].tap()
    }

    /// 上滑直到元素可点（首屏外条目）；超限不抛，由调用方 waitForExistence 兜底断言。
    static func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int) {
        for _ in 0..<maxSwipes where !element.isHittable {
            app.swipeUp()
        }
    }
}
