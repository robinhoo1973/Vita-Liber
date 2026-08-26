import XCTest

/// TC-M1a-01 端到端切片故事（test-plan-spec §4.2）：
/// 设 PIN → 建成员 → mock 相机注入处方样张 → OCR 字段逐一确认 → 时间轴可见。
/// waitForExistence 显式等待，禁止 sleep（test-plan §4.2 明令）。
final class M1aE2ETests: XCTestCase {

    private func launchFresh() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-camera-fixture"]
        app.launch()
        return app
    }

    private func typePin(_ pin: String, in app: XCUIApplication) {
        for ch in pin {
            app.buttons["SP-01.pin.key\(ch)"].tap()
        }
    }

    func test_端到端切片故事_PIN建档OCR确认时间轴() throws {
        let app = launchFresh()

        // L1 首启三卡
        for _ in 0..<3 {
            let confirm = app.buttons["SP-01.disclosure.confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10), "三卡必须逐一呈现")
            confirm.tap()
        }

        // 设 6 位 PIN「135790」
        typePin("135790", in: app)

        // 建成员「本人」
        let nameField = app.textFields["SP-06.owner.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("王女士")
        app.buttons["SP-06.owner.create"].tap()

        // 拍摄（mock 相机注入处方样张）
        let capture = app.buttons["SP-07.scan.capture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        capture.tap()

        // OCR 字段逐一确认（BR-003：未全部确认前 commit 不可用）
        let commit = app.buttons["SP-53.ocr.commit"]
        for key in ["drug_name", "dosage", "title"] {
            let confirmField = app.buttons["SP-53.field.confirm.\(key)"]
            XCTAssertTrue(confirmField.waitForExistence(timeout: 5), "字段 \(key) 必须呈现")
            confirmField.tap()
        }
        XCTAssertTrue(commit.waitForExistence(timeout: 5), "全部确认后 commit 可用")
        commit.tap()

        // 时间轴可见该文档
        let entry = app.otherElements["SP-10.timeline.entry"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "确认后的文档必须进入时间轴正式区")

        // 完成设置
        let finish = app.buttons["SP-01.onboarding.finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
    }

    /// FR1.4：退后台回前台必见锁屏；验证 PIN 后回到主界面
    func test_退后台回前台必见锁屏() throws {
        let app = launchFresh()
        // 先走完首启（复用端到端步骤）
        for _ in 0..<3 { app.buttons["SP-01.disclosure.confirm"].tap() }
        typePin("135790", in: app)
        let nameField = app.textFields["SP-06.owner.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap(); nameField.typeText("王女士")
        app.buttons["SP-06.owner.create"].tap()
        app.buttons["SP-07.scan.capture"].tap()
        for key in ["drug_name", "dosage", "title"] {
            app.buttons["SP-53.field.confirm.\(key)"].tap()
        }
        app.buttons["SP-53.ocr.commit"].tap()
        app.buttons["SP-01.onboarding.finish"].tap()

        // 退后台 → 回前台：必见锁屏遮罩
        XCUIDevice.shared.press(.home)
        app.activate()
        let lock = app.otherElements["SP-01.lockOverlay"]
        XCTAssertTrue(lock.waitForExistence(timeout: 10), "FR1.4：回前台必须见锁屏")

        // 验证 PIN 后回到主界面（五模块外壳可见）
        typePin("135790", in: app)
        XCTAssertTrue(app.buttons["SP-01.pin.key1"].waitForNonExistence(timeout: 10) || !app.otherElements["SP-01.lockOverlay"].exists,
                      "验证成功后锁屏遮罩必须消失")
    }
}
