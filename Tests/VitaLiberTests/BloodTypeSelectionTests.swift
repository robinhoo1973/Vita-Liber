import XCTest
@testable import VitaLiber

/// 血型 push button 的值分解：AB 不得被 A 前缀误匹配。
final class BloodTypeSelectionTests: XCTestCase {
    func testABODecompositionUsesWholeToken() {
        XCTAssertEqual(BloodTypeField.aboValue(from: "A+"), "A")
        XCTAssertEqual(BloodTypeField.aboValue(from: "B−"), "B")
        XCTAssertEqual(BloodTypeField.aboValue(from: "AB+"), "AB")
        XCTAssertEqual(BloodTypeField.aboValue(from: "AB−"), "AB")
        XCTAssertEqual(BloodTypeField.aboValue(from: "O"), "O")
    }

    func testNonStandardValuesHaveNoABO() {
        XCTAssertNil(BloodTypeField.aboValue(from: ""))
        XCTAssertNil(BloodTypeField.aboValue(from: "unknown"))
        XCTAssertNil(BloodTypeField.aboValue(from: "special"))
    }

    func testRHSuffix() {
        XCTAssertEqual(BloodTypeField.rhValue(from: "AB+"), "+")
        XCTAssertEqual(BloodTypeField.rhValue(from: "AB−"), "−")
        XCTAssertNil(BloodTypeField.rhValue(from: "AB"))
        XCTAssertNil(BloodTypeField.rhValue(from: "unknown"))
    }
}
