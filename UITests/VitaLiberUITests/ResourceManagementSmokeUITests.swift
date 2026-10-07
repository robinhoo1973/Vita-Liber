import XCTest

/// SP-64 统一「模型与数据资源」页冒烟（2026-09-28 B 计划项；2026-10-07 统一更新中心批更新锚）：
/// 入口可达 + 本机目录状态行常显 + 更新中心为唯一检查入口 + ASR 管理已并入本页。
/// 网络态不落 UI 测试（零隐式联网纪律：本页出现不触发任何请求）——由状态机单测承载。
final class ResourceManagementSmokeUITests: XCTestCase {
    func test_resourcePageReachesCatalogAndASRManagement() {
        let app = UITestSupport.makeSeededApp()
        UITestSupport.openTab("我的", in: app)

        let entry = app.descendants(matching: .any)["SP-64.settings.resources"].firstMatch
        UITestSupport.scrollToHittable(entry, in: app, maxSwipes: 8)
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "资源页入口必须在设置 > 健康记录内可达")
        entry.tap()

        // 本机目录状态行（本地与远端状态分离——重置态下也常显「目录尚不可用」）
        let local = app.descendants(matching: .any)["SP-64.medicalCatalog.local"].firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 10), "资源页必须常显本机目录状态行")

        // 统一更新中心（2026-10-07 批）：[检查全部更新] = 唯一检查入口（测试不做
        // 网络触发，只断言存在）；两域状态行常显。
        let checkAll = app.descendants(matching: .any)["SP-64.updateCenter.checkAll"].firstMatch
        XCTAssertTrue(checkAll.waitForExistence(timeout: 5), "更新中心必须呈现「检查全部更新」按钮")
        let asrRow = app.descendants(matching: .any)["SP-64.updateCenter.row.asr-models"].firstMatch
        XCTAssertTrue(asrRow.waitForExistence(timeout: 5), "更新中心必须呈现 ASR 域状态行")

        // ASR 管理已并入本页（B2-3）：家族行以资源页前缀存在。
        // 滚动护栏（评审修复）：目录段未来加行/小屏设备下可能推出屏外，
        // Form 屏外元素未必物化进 a11y 树——已可见时脚手架不滑动，零成本。
        let asrEngine = app.descendants(matching: .any)["SP-64.resource.asr.engine.whisper"].firstMatch
        UITestSupport.scrollToHittable(asrEngine, in: app, maxSwipes: 4)
        XCTAssertTrue(asrEngine.waitForExistence(timeout: 5), "语音模型管理必须并入统一资源页")
    }
}
