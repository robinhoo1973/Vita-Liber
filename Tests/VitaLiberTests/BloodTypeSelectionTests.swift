import XCTest
@testable import VitaLiber

/// 血型 push button 的值分解：AB 不得被 A 前缀误匹配。
final class BloodTypeSelectionTests: XCTestCase {
    func testABODecompositionUsesWholeToken() {
        XCTAssertEqual(BloodTypePushGrid.aboValue(from: "A+"), "A")
        XCTAssertEqual(BloodTypePushGrid.aboValue(from: "B−"), "B")
        XCTAssertEqual(BloodTypePushGrid.aboValue(from: "AB+"), "AB")
        XCTAssertEqual(BloodTypePushGrid.aboValue(from: "AB−"), "AB")
        XCTAssertEqual(BloodTypePushGrid.aboValue(from: "O"), "O")
    }

    func testNonStandardValuesHaveNoABO() {
        XCTAssertNil(BloodTypePushGrid.aboValue(from: ""))
        XCTAssertNil(BloodTypePushGrid.aboValue(from: "unknown"))
        XCTAssertNil(BloodTypePushGrid.aboValue(from: "special"))
    }

    func testRHSuffix() {
        XCTAssertEqual(BloodTypePushGrid.rhValue(from: "AB+"), "+")
        XCTAssertEqual(BloodTypePushGrid.rhValue(from: "AB−"), "−")
        XCTAssertNil(BloodTypePushGrid.rhValue(from: "AB"))
        XCTAssertNil(BloodTypePushGrid.rhValue(from: "unknown"))
    }
}
