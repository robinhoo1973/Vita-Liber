import XCTest

/// TC-M1a-01 端到端切片故事（test-plan-spec §4.2，随 function-spec V3.39 简化向导对齐）：
/// 三卡 → 建成员「本人」→ 添加家人步（可跳过）→ 向导完成 → 首页空态引导卡呈现。
/// V3.39：向导不再包含 mock 相机样张/OCR 字段确认/时间轴步骤——BR-003 确认闸门与
/// 字段级确认/修订语义由 M1aAcceptanceTests 在单元层覆盖（直测 DocumentsState.commitDraft
/// / DocumentStore.confirmText 活管线 + Domain 层 OcrConfirmationTests）；
/// 生产资料采集走 SP-11 快速拍摄/SP-10 资料库管线（XCUITest 无法驱动相机/相册picker，归 L2）。
/// 门禁旁路 -uitest-gate-bypass：本会话视为已认证，避免完成后锁屏遮罩顶掉断言。
/// waitForExistence 显式等待，禁止 sleep（test-plan §4.2 明令）。
// binds: SU-M1a-E2E / SU-M1a-SEC — TC-M1a-01/02
final class M1aE2ETests: XCTestCase {

    private func launchFresh() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-gate-bypass"]
        app.launch()
        return app
    }

    private func launchAtFamilyStep() -> XCUIApplication {
        let app = launchFresh()

        // L1 首启三卡
        for _ in 0..<3 {
            let confirm = app.buttons["SP-01.disclosure.confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10), "三卡必须逐一呈现")
            confirm.tap()
        }

        // 建成员「本人」
        let nameField = app.textFields["SP-06.owner.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("王女士")
        app.buttons["SP-06.owner.create"].tap()
        XCTAssertTrue(app.buttons["FR21.9.step4.skip"].waitForExistence(timeout: 5))
        return app
    }

    func test_SU_M1a_E2E_端到端切片故事_三卡建档家人完成进首页() throws {
        let app = launchAtFamilyStep()

        // FR21.9 ④ 添加家人（可跳过）：V3.39 起为向导最后一步——跳过即完成向导
        let skipFamily = app.buttons["FR21.9.step4.skip"]
        XCTAssertTrue(skipFamily.waitForExistence(timeout: 5), "建档后必须呈现添加家人步")
        skipFamily.tap()

        // 向导完成 → 首页空态引导卡（首日引导由 SP-04 首页承载）
        let guide = app.descendants(matching: .any)["SP-04.home.emptyGuide"].firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: 8),
                      "完成向导后必须呈现首页空态引导卡（首日引导改由首页承载）")

        // FR2.1b/SP-04 回归：注册后的可选档案进度可见，不能吞掉首日引导。
        let progress = app.buttons["SP-04.home.profileProgress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "资料未完善时必须有可操作的进度入口")
        let memberSwitch = app.buttons["SP-04.home.memberSwitch"]
        XCTAssertTrue(memberSwitch.waitForExistence(timeout: 5))
        // 以实际成员按钮为锚点，覆盖空 large-title 区；不硬编码状态栏/刘海高度。
        XCTAssertLessThanOrEqual(progress.frame.minY - memberSwitch.frame.maxY, 48,
                                 "工具栏与首个内容间不应保留空白大标题或空进度容器")

        // 回归护栏：向导内绝不再出现强制拍摄步（M1a 切片残留）——
        // 置于首页断言之后用零成本 exists 判定：若拍摄步被错误加回向导，
        // 流程将停在拍摄页、上面 guide 断言先红（本断言提供更直接的失败定位）
        let legacyScan = app.buttons["SP-07.scan.capture"]
        XCTAssertFalse(legacyScan.exists,
                       "V3.39：首启向导不再含拍摄/OCR 步骤")
    }

    // binds: SU-M1c-REGRESSION — TC-M1c-08 / SP-04
    func test_无当前档案时不显示进度或保留顶部空块() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-finished", "-uitest-gate-bypass"]
        app.launch()
        let guide = app.descendants(matching: .any)["SP-04.home.emptyGuide"].firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["SP-04.home.profileProgress"].exists,
                       "当前档案不存在时不应显示伪造的 0/8 进度")
        let memberSwitch = app.buttons["SP-04.home.memberSwitch"]
        XCTAssertTrue(memberSwitch.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(guide.frame.minY - memberSwitch.frame.maxY, 48,
                                 "进度不显示时，首日引导必须向上收拢")
    }

    // binds: SU-M1c-REGRESSION — TC-M1c-08 / BR-001
    func test_换成员后再次进入同一访谈路由会重置旧步骤() throws {
        let app = launchAtFamilyStep()
        app.buttons["FR21.9.step4.manual"].tap()
        let name = app.textFields["FR3.7.create.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("小王")
        app.buttons["FR3.7.create.save"].tap()
        let addedAlert = app.alerts.firstMatch
        XCTAssertTrue(addedAlert.waitForExistence(timeout: 5))
        addedAlert.buttons.element(boundBy: 0).tap()
        app.buttons["FR21.9.step4.skip"].tap()

        let progress = app.buttons["SP-04.home.profileProgress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        progress.tap()
        let touch = app.buttons["FR17.12.useTouch"]
        XCTAssertTrue(touch.waitForExistence(timeout: 5))
        touch.tap()
        let skipStep = app.buttons["FR17.11.skip"]
        XCTAssertTrue(skipStep.waitForExistence(timeout: 5))
        skipStep.tap() // A 停在第二问；不启动录音、不依赖输入键盘的收起行为。

        // 仅切 Tab，故意保留 Me 栈顶 .voiceGuideProfile，复现路由去重场景。
        app.tabBars.buttons["首页"].tap()
        let switchMember = app.buttons["SP-04.home.memberSwitch"]
        XCTAssertTrue(switchMember.waitForExistence(timeout: 5))
        switchMember.tap()
        let child = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                     "SP-05.member.", "小王")).firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 5))
        child.tap()
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        progress.tap()

        // 须知已经接受，B 应从自检/触屏入口重新开始，不能继续 A 的第二问。
        XCTAssertTrue(app.buttons["voice.mic.pass"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["FR17.11.answer"].firstMatch.exists)
    }

    /// FR1.4：冷启动/退后台回前台必见锁屏；系统认证成功（桩注入）后回到主界面。
    /// XCUITest 无法自动化 Face ID → -uitest-gate-stub-success 注入确定性成功；
    /// -uitest-gate-no-auto 关掉遮罩出现的自动认证（避免在断言前被桩自动放行）。
    /// 用 -uitest-seed-finished 确定性注入完成态（门禁生效），不依赖前序用例持久化。
    func test_SU_M1a_SEC_退后台回前台必见锁屏() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed-finished", "-uitest-gate-stub-success",
                               "-uitest-gate-no-auto"]
        app.launch()

        // 冷启动未认证 → 锁屏遮罩必须存在
        let lock = app.descendants(matching: .any)["SP-01.lockOverlay"].firstMatch
        XCTAssertTrue(lock.waitForExistence(timeout: 10), "FR1.4：冷启动必见锁屏遮罩")

        // 退后台 → 回前台：锁屏遮罩仍在（backgroundLocked 置位）
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(lock.waitForExistence(timeout: 10), "FR1.4：回前台必须见锁屏")

        // 点解锁 → 桩认证成功 → 遮罩消失回到主界面
        let unlock = app.buttons["SP-01.lockOverlay.unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 5))
        unlock.tap()
        let lockGone = app.descendants(matching: .any)["SP-01.lockOverlay"].firstMatch
        XCTAssertTrue(lockGone.waitForNonExistence(timeout: 10),
                      "认证成功后锁屏遮罩必须消失")
    }
}
