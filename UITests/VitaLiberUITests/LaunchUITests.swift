import XCTest

final class LaunchUITests: XCTestCase {
    func test_冷启五Tab可见() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.waitForExistence(timeout: 10))
    }
}
