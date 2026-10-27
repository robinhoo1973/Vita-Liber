import XCTest
@testable import VitaLiber

/// 延期判定（7 天窗口，注入时钟）与完成后自动进入调度器。
final class CatalogPromptSupportTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testDeferralWindowBoundaries() {
        let day: TimeInterval = 24 * 60 * 60
        XCTAssertTrue(CatalogPromptDeferral.isDeferred(
            now: base.addingTimeInterval(6 * day + 23 * 3600), lastDeferredAt: base))
        XCTAssertFalse(CatalogPromptDeferral.isDeferred(
            now: base.addingTimeInterval(7 * day), lastDeferredAt: base),
            "恰好 7 天即到期，不再延期")
        XCTAssertFalse(CatalogPromptDeferral.isDeferred(now: base, lastDeferredAt: nil))
    }

    @MainActor
    func testSchedulerFiresOnceAndIgnoresSecondSchedule() async {
        let scheduler = CatalogAutoEnterScheduler()
        let fired = expectation(description: "auto enter")
        fired.assertForOverFulfill = true
        scheduler.schedule(after: .milliseconds(20)) { fired.fulfill() }
        scheduler.schedule(after: .milliseconds(20)) { XCTFail("重复调度应被忽略") }
        await fulfillment(of: [fired], timeout: 2)
    }

    @MainActor
    func testSchedulerCancelPreventsEntry() async {
        let scheduler = CatalogAutoEnterScheduler()
        let fired = expectation(description: "must not fire")
        fired.isInverted = true
        scheduler.schedule(after: .milliseconds(60)) { fired.fulfill() }
        scheduler.cancel()
        await fulfillment(of: [fired], timeout: 0.2)
    }
}
