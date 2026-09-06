import XCTest

// binds: SU-M0-SMOKE — 冷启五 Tab 可见
final class LaunchUITests: XCTestCase {
    func test_冷启五Tab可见() {
        // 审查修复：原断言只有 waitForExistence——五 Tab 一个都不查，
        // 删掉全部 Tab 或门禁回归均照常绿灯（「断言不存在的断言」）。
        // 独立启动参数隔离此用例与其它用例的持久化状态。
        // 评审修正：补 -uitest-seed-finished——否则新模拟器首启走 OnboardingFlowView，
        // Tab 栏永远不出现；此前只在「前序用例泄漏了完成态」的脏环境里通过
        // （同 M1aE2ETests 的确定性注入纪律）。
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-gate-bypass", "-uitest-seed-finished"]
        app.launch()
        XCTAssertTrue(app.waitForExistence(timeout: 10))
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "冷启必须渲染 Tab 栏")
        // 五个 Tab 的本地化标题（zh-Hans 默认环境；L10n.nav*）
        let titles = ["首页", "记录", "提醒", "AI", "我的"]
        for title in titles {
            XCTAssertTrue(tabBar.buttons[title].exists, "缺失 Tab \(title)")
        }
    }
}
