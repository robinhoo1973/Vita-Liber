import XCTest

/// SP-64 统一「模型与数据资源」页冒烟（2026-09-28 B 计划项）：
/// 入口可达 + 本机目录状态行常显 + 检查按钮唯一网络触发入口 + ASR 管理已并入本页。
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

        // 检查按钮 = 唯一网络触发入口（测试不做网络触发，只断言存在）
        let check = app.descendants(matching: .any)["SP-64.medicalCatalog.check"].firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 5), "未检查态必须呈现「检查更新」按钮")

        // ASR 管理已并入本页（B2-3）：检查更新按钮以资源页前缀存在
        let asrCheck = app.descendants(matching: .any)["SP-64.resource.asr.model.checkUpdate"].firstMatch
        XCTAssertTrue(asrCheck.waitForExistence(timeout: 5), "语音模型管理必须并入统一资源页")
    }
}
