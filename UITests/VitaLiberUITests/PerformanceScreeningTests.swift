import XCTest

/// tech §8 性能预算 · 模拟器初筛口径（真机复测归 L2）
// binds: SU-M0-PERF / SU-M1c-PERF — TC-M0-08 / TC-M1c-05
final class PerformanceScreeningTests: XCTestCase {
    /// TC-M0-08：XCTApplicationLaunchMetric 自身负责每轮迭代间的终止与重启，
    /// 被测闭包内只需 `launch()`——闭包里再调 terminate() 会把拆卸耗时计入指标。
    func test_SU_M0_PERF_SU_M1c_PERF_冷启动基线初筛() throws {
        if #available(iOS 16.0, *) {
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
