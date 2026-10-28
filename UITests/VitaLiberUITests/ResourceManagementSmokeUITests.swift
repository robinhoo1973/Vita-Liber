import XCTest

/// SP-64 统一「医疗数据与离线资源」页冒烟（2026-09-28 B 计划项；2026-10-27 域内检查入口批）：
/// 入口可达 + 本机目录状态行常显 + 更新中心批处理 + 医疗域单域检查快捷键 + ASR 管理并入本页。
/// 网络态不落 UI 测试（零隐式联网纪律：本页出现不触发任何请求）；pinned root 随包后
/// 点按检查会真实联网，离线用例必须用 -uitest-catalog-checker-off 旁路。
final class ResourceManagementSmokeUITests: XCTestCase {
    func test_resourcePageReachesCatalogAndASRManagement() {
        let app = UITestSupport.makeSeededApp()
        UITestSupport.openTab("我的", in: app)

        let entry = app.descendants(matching: .any)["SP-64.settings.resources"].firstMatch
        UITestSupport.scrollToHittable(entry, in: app, maxSwipes: 8)
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "资源页入口必须在设置 > 健康记录内可达")
        entry.tap()

        // 三切片聚合摘要行（2026-10-28 切片-only：三行+摘要常显；重置态「已装 0/3」）
        let summary = app.descendants(matching: .any)["SP-64.catalogSlices.summary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "资源页必须常显三类目录聚合摘要行")

        // 统一更新中心（2026-10-07 批；2026-10-27 D4 修订）：[检查全部更新] = 跨域
        // 批处理入口（测试不做网络触发，只断言存在）；医疗域另有单域快捷键。
        let checkAll = app.descendants(matching: .any)["SP-64.updateCenter.checkAll"].firstMatch
        XCTAssertTrue(checkAll.waitForExistence(timeout: 5), "更新中心必须呈现「检查全部更新」按钮")
        // 医疗域单域检查入口存在且空闲可用（不点击——点按会真实联网）。
        let domainCheck = app.descendants(matching: .any)["SP-64.medicalCatalog.check"].firstMatch
        XCTAssertTrue(domainCheck.waitForExistence(timeout: 5), "医疗域必须有独立检查入口")
        XCTAssertTrue(domainCheck.isEnabled)
        let asrRow = app.descendants(matching: .any)["SP-64.updateCenter.row.asr-models"].firstMatch
        XCTAssertTrue(asrRow.waitForExistence(timeout: 5), "更新中心必须呈现 ASR 域状态行")

        // ASR 管理已并入本页（B2-3）：家族行以资源页前缀存在。
        // 滚动护栏（评审修复）：目录段未来加行/小屏设备下可能推出屏外，
        // Form 屏外元素未必物化进 a11y 树——已可见时脚手架不滑动，零成本。
        let asrEngine = app.descendants(matching: .any)["SP-64.resource.asr.engine.whisper"].firstMatch
        UITestSupport.scrollToHittable(asrEngine, in: app, maxSwipes: 4)
        XCTAssertTrue(asrEngine.waitForExistence(timeout: 5), "语音模型管理必须并入统一资源页")
    }

    /// checker==nil 旁路（-uitest-catalog-checker-off）：点检查 → 零网络 → 「暂不可用」，
    /// 标题变「重新检查」，不出现下载/更新按钮（FR25.13 零隐式联网与 fail-closed）。
    func test_medicalCatalogCheck_offlineUnavailable() {
        let app = UITestSupport.makeSeededApp(extraArguments: ["-uitest-catalog-checker-off"])
        UITestSupport.openTab("我的", in: app)

        let entry = app.descendants(matching: .any)["SP-64.settings.resources"].firstMatch
        UITestSupport.scrollToHittable(entry, in: app, maxSwipes: 8)
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()

        let check = app.descendants(matching: .any)["SP-64.medicalCatalog.check"].firstMatch
        UITestSupport.scrollToHittable(check, in: app, maxSwipes: 8)
        XCTAssertTrue(check.waitForExistence(timeout: 10))
        XCTAssertTrue(check.isEnabled)
        check.tap()

        let recheck = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "重新检查"), object: check)
        XCTAssertEqual(XCTWaiter.wait(for: [recheck], timeout: 5), .completed,
                       "检查落定后标题应变为「重新检查」")
        XCTAssertFalse(
            app.descendants(matching: .any)["SP-64.medicalCatalog.update"].firstMatch.exists,
            "无候选时不得出现更新按钮")
    }
}
