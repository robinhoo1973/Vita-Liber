import XCTest

/// Shared presentation-test scaffolding（2026-09-26 审查修复：三份 launch-args 样板 +
/// 两份 swipe-until-hittable 循环此前各自复制、容差漂移）。
/// 自由函数形态（非 XCTestCase 子类），避免被测试发现器当成测试类。
enum UITestSupport {
    /// 重置态种子 App（-uitest-reset 清库 + 建档流程已完成 + 门禁绕过）。
    /// `extraArguments`：用例级旁路（如 -uitest-catalog-checker-off）。
    static func makeSeededApp(reset: Bool = true,
                              extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-uitest-gate-bypass", "-uitest-seed-finished"]
        if reset { args.insert("-uitest-reset", at: 0) }
        args.append(contentsOf: extraArguments)
        app.launchArguments = args
        app.launch()
        return app
    }

    /// 等 Tab 栏出现并切到指定 Tab（zh-Hans 界面字面量）。
    static func openTab(_ name: String, in app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "Tab bar did not appear")
        // iOS 26 模拟器在部分恢复态下会同时暴露 tab 包装按钮与带 identifier
        // 的真实按钮（同一 label），`buttons[name].tap()` 因多匹配而失败。
        // 取 firstMatch 只消除系统重复暴露，不改变实际 tab 选择。
        tabBar.buttons[name].firstMatch.tap()
    }

    /// 上滑直到元素可点（首屏外条目）；超限不抛，由调用方 waitForExistence 兜底断言。
    static func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int) {
        for _ in 0..<maxSwipes where !element.isHittable {
            app.swipeUp()
        }
    }

    /// 等到可点再点击（TD 2026-10-29；run 40812706085 retry-masked 抖动复核）：
    /// `waitForExistence` 通过 ≠ 可点——sheet 转场/动画期间元素刚出现又重排，
    /// 紧接着的 tap 会以「No matches found」硬失败（MemberViews 首轮实证）。
    /// 轮询 isHittable 至截止（默认 10s）再点击；超限仍点击一次，
    /// 失败由 XCUITest 原生错误如实暴露（不吞错）。
    static func tapWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isHittable && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        element.tap()
    }
}
