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
}
