import XCTest

/// SP-65 任务型 AI 助手：入口可达、空态输入、确认卡出现并可关闭。
/// B1 随包脚本定标在启动时通过，入口默认可见；若定标缺件则本测试会红——
/// 这是有意的 fail-closed 断言。
final class AssistantChatUITests: XCTestCase {

    private func launchToHome() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed-finished", "-uitest-gate-bypass"]
        app.launch()
        return app
    }

    func testAssistantEntryOpensChatAndShowsInput() {
        let app = launchToHome()
        let entry = app.buttons["SP-04.home.assistant"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "B1 定标通过时首页必须显示助手入口")
        entry.tap()

        let input = app.descendants(matching: .any)["assistant.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["assistant.send"].exists)
        XCTAssertTrue(app.buttons["assistant.close"].exists)
    }

    func testNoteFlowReachesStandardConfirmation() {
        let app = launchToHome()
        let entry = app.buttons["SP-04.home.assistant"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()

        let input = app.descendants(matching: .any)["assistant.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("记一下")
        app.buttons["assistant.send"].tap()

        let confirm = app.buttons["FR17.13.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "必须走 FR17.13 标准确认卡")
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))

        app.buttons["assistant.close"].tap()
    }

    func testEmergencyDoesNotProduceConfirmationCard() {
        let app = launchToHome()
        let entry = app.buttons["SP-04.home.assistant"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()

        let input = app.descendants(matching: .any)["assistant.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("我胸痛喘不上气")
        app.buttons["assistant.send"].tap()

        // 急救路径：会话关闭并进 SOS；不得出现任何确认卡/动作。
        XCTAssertFalse(app.buttons["FR17.13.confirm"].waitForExistence(timeout: 3))
    }
}
