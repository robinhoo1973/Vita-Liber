import XCTest

/// tech §8 性能预算 · 模拟器初筛口径（真机复测归 L2）
final class PerformanceScreeningTests: XCTestCase {
    func test_冷启动基线初筛() throws {
        if #available(iOS 16.0, *) {
            let app = XCUIApplication()
            let metric = XCTApplicationLaunchMetric()
            measure(metrics: [metric]) { app.launchAndTerminate() }
        }
    }
}
