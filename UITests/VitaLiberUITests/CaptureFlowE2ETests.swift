import XCTest

/// TC-M1a-01 端到端切片故事（test-plan-spec §4.2，随 function-spec V3.39 简化向导对齐）：
/// 三卡 → 建成员「本人」→ 添加家人步（可跳过）→ 向导完成 → 首页空态引导卡呈现。
/// V3.39：向导不再包含 mock 相机样张/OCR 字段确认/时间轴步骤——BR-003 确认闸门与
/// 字段级确认/修订语义由 SecurityGateAcceptanceTests 在单元层覆盖（直测 DocumentsState.commitDraft
/// / DocumentStore.confirmText 活管线 + Domain 层 OcrConfirmationTests）；
/// 生产资料采集走 SP-11 快速拍摄/SP-10 资料库管线（XCUITest 无法驱动相机/相册picker，归 L2）。
/// 门禁旁路 -uitest-gate-bypass：本会话视为已认证，避免完成后锁屏遮罩顶掉断言。
/// waitForExistence 显式等待，禁止 sleep（test-plan §4.2 明令）。
// binds: SU-M1a-E2E / SU-M1a-SEC — TC-M1a-01/02
final class CaptureFlowE2ETests: XCTestCase {

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

        // 建成员「本人」（业主 2026-09-17 定：注册必填 = 特征性数据 + 紧急联系人；
        // 菜单 Picker 点击同时收起键盘——数字键盘族经工具栏「确认」收起）
        let nameField = app.textFields["SP-06.owner.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("王女士")

        app.buttons["SP-06.owner.gender"].tap()
        let femaleOption = app.buttons["女"]
        XCTAssertTrue(femaleOption.waitForExistence(timeout: 3), "性别菜单必须呈现")
        femaleOption.tap()

        let yearField = app.textFields["SP-06.owner.birthYear"]
        yearField.tap()
        yearField.typeText("1975")
        app.buttons["SP-06.owner.dismissKeyboard"].tap()

        // 2026-10-29 血型改单列表单选（行 → sheet → 选项），两步网格退役。
        app.buttons["bloodType.select"].tap()
        let bloodOption = app.buttons["bloodType.option.Opos"].firstMatch
        XCTAssertTrue(bloodOption.waitForExistence(timeout: 5), "血型选项面板必须呈现")
        bloodOption.tap()

        // 键盘避让：每输完一个文本字段先收起键盘再点下一个
        //（键盘弹起时 phone 字段在键盘下方，tap 会打到键盘 → 无焦点 → typeText 失败）
        let contactName = app.textFields["SP-06.owner.contact.name"]
        contactName.tap()
        contactName.typeText("李四")
        app.buttons["SP-06.owner.dismissKeyboard"].tap()
        let contactPhone = app.textFields["SP-06.owner.contact.phone"]
        contactPhone.tap()
        contactPhone.typeText("13800138000")
        app.buttons["SP-06.owner.dismissKeyboard"].tap()

        app.buttons["SP-06.owner.create"].tap()
        XCTAssertTrue(app.buttons["FR21.9.step4.skip"].waitForExistence(timeout: 5))
        return app
    }

    /// 原名：test_SU_M1a_E2E_端到端切片故事_三卡建档家人完成进首页
    func test_SU_M1a_E2E_endToEndSliceStory_threeCardsFamilyCompleteToHome() throws {
        let app = launchAtFamilyStep()

        // FR21.9 ④ 添加家人（可跳过）：V3.39 起为向导最后一步——跳过即完成向导
        let skipFamily = app.buttons["FR21.9.step4.skip"]
        XCTAssertTrue(skipFamily.waitForExistence(timeout: 5), "建档后必须呈现添加家人步")
        skipFamily.tap()

        // 向导完成 → 首页空态引导卡（首日引导由 SP-04 首页承载）
        let guide = app.descendants(matching: .any)["SP-04.home.emptyGuide"].firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: 8),
                      "完成向导后必须呈现首页空态引导卡（首日引导改由首页承载）")

        // FR2.1b/SP-04 回归（2026-10-23）：血型+生日均已在首启登记 → 首页
        // 登记卡必须消失；首日引导仍在，不能因登记卡消失吞掉引导。
        XCTAssertFalse(app.buttons["SP-04.home.profileProgress"].exists,
                       "全部登记后首页不再显示登记卡")
        let memberSwitch = app.buttons["SP-04.home.memberSwitch"]
        XCTAssertTrue(memberSwitch.waitForExistence(timeout: 5))
        // 以实际成员按钮为锚点，覆盖空 large-title 区；不硬编码状态栏/刘海高度。
        XCTAssertLessThanOrEqual(guide.frame.minY - memberSwitch.frame.maxY, 48,
                                 "工具栏与首个内容间不应保留空白大标题或空登记卡")

        // 回归护栏：向导内绝不再出现强制拍摄步（M1a 切片残留）——
        // 置于首页断言之后用零成本 exists 判定：若拍摄步被错误加回向导，
        // 流程将停在拍摄页、上面 guide 断言先红（本断言提供更直接的失败定位）
        let legacyScan = app.buttons["SP-07.scan.capture"]
        XCTAssertFalse(legacyScan.exists,
                       "V3.39：首启向导不再含拍摄/OCR 步骤")
    }

    // binds: SU-M1c-REGRESSION — TC-M1c-08 / SP-04
    /// 原名：test_无当前档案时不显示进度或保留顶部空块
    func test_noCurrentProfileShowsNoProgressOrEmptyTopBlock() throws {
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
    /// FR1.4：冷启动/退后台回前台必见锁屏；系统认证成功（桩注入）后回到主界面。
    /// XCUITest 无法自动化 Face ID → -uitest-gate-stub-success 注入确定性成功；
    /// -uitest-gate-no-auto 关掉遮罩出现的自动认证（避免在断言前被桩自动放行）。
    /// 用 -uitest-seed-finished 确定性注入完成态（门禁生效），不依赖前序用例持久化。
    /// 原名：test_SU_M1a_SEC_退后台回前台必见锁屏
    func test_SU_M1a_SEC_backgroundForegroundMustSeeLockScreen() throws {
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
