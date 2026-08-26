import XCTest
@testable import VitaLiber

final class SmokeTests: XCTestCase {
    func test_MainModule_五枚举完整() { XCTAssertEqual(MainModule.allCases.count, 5) }
}
