import XCTest

/// TC-M1a-01 端到端切片故事（test-plan-spec §4.2）：
/// 设 PIN → 建成员 → mock 相机注入处方样张 → OCR 字段逐一确认 → 时间轴可见。
/// waitForExistence 显式等待，禁止 sleep（test-plan §4.2 明令）。
// binds: SU-M1a-E2E / SU-M1a-SEC — TC-M1a-01/02
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

    func test_SU_M1a_E2E_端到端切片故事_PIN建档OCR确认时间轴() throws {
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

        // OCR 字段确认 → 改一条字段留修订历史（FR6.4 退出准则步骤）
        let commit = app.buttons["SP-53.ocr.commit"]
        // 剂量字段：确认 → 修改 → 保存（旧值入修订历史）
        let confirmDosage = app.buttons["SP-53.field.confirm.dosage"]
        XCTAssertTrue(confirmDosage.waitForExistence(timeout: 5))
        confirmDosage.tap()
        let editDosage = app.buttons["SP-53.field.edit.dosage"]
        XCTAssertTrue(editDosage.waitForExistence(timeout: 5), "确认后必须出现修改入口")
        editDosage.tap()
        let editField = app.textFields["SP-53.field.editField"]
        XCTAssertTrue(editField.waitForExistence(timeout: 5))
        editField.tap()
        editField.typeText("每日两次")
        app.buttons["SP-53.field.editSave"].tap()
        // 其余字段逐一确认（BR-003：未全部确认前 commit 不可用）
        for key in ["drug_name", "title"] {
            let confirmField = app.buttons["SP-53.field.confirm.\(key)"]
            XCTAssertTrue(confirmField.waitForExistence(timeout: 5), "字段 \(key) 必须呈现")
            confirmField.tap()
        }
        XCTAssertTrue(commit.waitForExistence(timeout: 5), "全部确认后 commit 可用")
        commit.tap()

        // 时间轴可见该文档（List 行是 cell 元素；用 descendants(.any) 容忍类型差异）
        let entry = app.descendants(matching: .any)["SP-10.timeline.entry"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 8), "确认后的文档必须进入时间轴正式区")

        // 完成设置
        let finish = app.buttons["SP-01.onboarding.finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
    }

    /// FR1.4：退后台回前台必见锁屏；验证 PIN 后回到主界面。
    /// 用 -uitest-seed-finished 确定性注入完成态（PIN=135790），
    /// 不依赖前序用例的持久化数据。
    func test_SU_M1a_SEC_退后台回前台必见锁屏() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed-finished"]
        app.launch()

        // 退后台 → 回前台：必见锁屏遮罩
        XCUIDevice.shared.press(.home)
        app.activate()
        let lock = app.descendants(matching: .any)["SP-01.lockOverlay"].firstMatch
        XCTAssertTrue(lock.waitForExistence(timeout: 10), "FR1.4：回前台必须见锁屏")

        // 验证 PIN 后回到主界面（锁屏遮罩消失）
        typePin("135790", in: app)
        let lockGone = app.descendants(matching: .any)["SP-01.lockOverlay"].firstMatch
        XCTAssertTrue(lockGone.waitForNonExistence(timeout: 10),
                      "验证成功后锁屏遮罩必须消失")
    }
}
