import XCTest
@testable import VitaLiber

// binds: SU-M15-VOICE (FR17.1)
final class DictationPressStateTests: XCTestCase {
    func test_shortPressTogglesExactlyOnce() {
        var state = DictationPressState()
        _ = state.begin()
        XCTAssertEqual(state.end(cancelled: false), .toggle)
        XCTAssertEqual(state.end(cancelled: true), .none)
    }

    func test_recognizedHoldStopsInsteadOfTogglingOnRelease() {
        var state = DictationPressState()
        let id = state.begin()
        XCTAssertTrue(state.recognize(id))
        XCTAssertFalse(state.recognize(id))
        XCTAssertEqual(state.end(cancelled: false), .stop)
        XCTAssertEqual(state.end(cancelled: false), .none)
    }

    func test_cancelledPressCannotBeStartedByItsLateTimer() {
        var state = DictationPressState()
        let old = state.begin()
        XCTAssertEqual(state.end(cancelled: true), .none)
        let current = state.begin()
        XCTAssertFalse(state.recognize(old))
        XCTAssertTrue(state.recognize(current))
        XCTAssertEqual(state.end(cancelled: true), .stop)
    }

    /// 业主 2026-09-16 第 5 项：轻点 = 开关（开始/结束），按住 ≥ 阈值 = 按住说话。
    /// 阈值必须**长于一次正常点击**——0.2s 时普通点击被判成「按住」，识别在阈值处
    /// 启动、抬手即停，得到一段空录音并报「未识别到语音」（点击开始的实际症状）。
    func test_holdThresholdIsLongerThanANormalTap() {
        XCTAssertGreaterThanOrEqual(DictationPressState.holdThreshold, 0.4)
        XCTAssertLessThanOrEqual(DictationPressState.holdThreshold, 1.0)
        // 纳秒出口与秒值同源（视图用纳秒，避免第二份字面量）
        XCTAssertEqual(DictationPressState.holdThresholdNanoseconds,
                       UInt64(DictationPressState.holdThreshold * 1_000_000_000))
    }
}
