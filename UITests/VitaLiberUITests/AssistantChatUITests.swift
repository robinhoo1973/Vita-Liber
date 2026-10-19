import XCTest

/// SP-65 任务型 AI 助手：入口可达、空态输入、确认卡出现并可关闭。
/// B1 随包脚本定标在启动时通过，入口默认可见；若定标缺件则本测试会红——
/// 这是有意的 fail-closed 断言。
final class AssistantChatUITests: XCTestCase {

    private func launchToHome() -> XCUIApplication {
        let app = XCUIApplication()
        // 每个用例必须从确定性状态起步：既有测试会改选中 Tab/路由，
        // 不 reset 时 AppRouter 会恢复上一个用例的 Tab（CI 39133209405
        // 实测：落在健康档案页，首页工具栏不存在）。
        app.launchArguments = ["-uitest-reset", "-uitest-seed-finished", "-uitest-gate-bypass"]
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
        XCTAssertTrue(app.buttons["assistant.modeToggle"].exists)
        XCTAssertTrue(app.buttons["assistant.attach"].exists, "空输入时右端为附件 ＋")
        XCTAssertFalse(app.buttons["assistant.send"].exists, "空输入时不显示发送")
        XCTAssertTrue(app.buttons["assistant.close"].exists)
    }

    /// 2026-10-19 微信式输入栏：语音/键盘切换 + 附件面板。
    func testVoiceModeToggleSwapsComposer() {
        let app = launchToHome()
        app.buttons["SP-04.home.assistant"].tap()

        let toggle = app.buttons["assistant.modeToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(app.buttons["assistant.voiceTap"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["assistant.input"].exists)

        toggle.tap()
        XCTAssertTrue(app.descendants(matching: .any)["assistant.input"].waitForExistence(timeout: 5))
    }

    func testAttachmentPanelShowsPhotoAndPDF() {
        let app = launchToHome()
        app.buttons["SP-04.home.assistant"].tap()

        let attach = app.buttons["assistant.attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        attach.tap()
        XCTAssertTrue(app.buttons["assistant.attach.photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["assistant.attach.pdf"].exists)

        attach.tap()
        XCTAssertTrue(app.buttons["assistant.attach.photos"].waitForNonExistence(timeout: 5))
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
        let send = app.buttons["assistant.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "有文本时右端换成发送")
        send.tap()

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
        let send = app.buttons["assistant.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()

        // 急救路径：会话关闭并进 SOS；不得出现任何确认卡/动作。
        XCTAssertFalse(app.buttons["FR17.13.confirm"].waitForExistence(timeout: 3))
    }
}
