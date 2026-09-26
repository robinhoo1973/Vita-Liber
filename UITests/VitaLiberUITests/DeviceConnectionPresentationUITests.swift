import XCTest

/// Presentation regression for the SP-29 settings route and the reset-state authorization flow.
///
/// 2026-09-26 审查修复：原断言 `SP-29.health.unavailable`（设备不提供 HealthKit 态）——
/// 该态在 L1 目标（iPhone 15 模拟器，`HKHealthStore.isHealthDataAvailable() == true`）不可达，
/// 页面实际落在 `.ownerMissing`（-uitest-reset 清库后无本人档案）。改为断言真实落点。
final class DeviceConnectionPresentationUITests: XCTestCase {
    func test_connectionSettingsReachOwnerMissingStateOnReset() {
        let app = UITestSupport.makeSeededApp()
        UITestSupport.openTab("我的", in: app)

        let healthEntry = app.descendants(matching: .any)["SP-25.settings.appleHealth"].firstMatch
        UITestSupport.scrollToHittable(healthEntry, in: app, maxSwipes: 8)
        XCTAssertTrue(healthEntry.waitForExistence(timeout: 5))
        healthEntry.tap()

        let ownerMissing = app.descendants(matching: .any)["SP-29.health.ownerMissing"].firstMatch
        XCTAssertTrue(ownerMissing.waitForExistence(timeout: 10),
                      "The connection page must keep its explicit no-owner state after a reset")
        XCTAssertFalse(app.descendants(matching: .any)["SP-29.health.requestAuth"].exists,
                       "Without an owner profile the page must not expose a request-authorization action")
    }
}
