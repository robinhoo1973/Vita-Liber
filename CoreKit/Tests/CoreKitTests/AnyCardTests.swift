import XCTest
@testable import Domain

final class AnyCardTests: XCTestCase {

    func testEncodeAndDecode() throws {
        var record = PatientRecord()
        record.name = "张三"
        record.gender = "男"

        let anyCard = try AnyCard(record)
        XCTAssertEqual(anyCard.cardType, "patient")

        let decoded = try anyCard.decode(as: PatientRecord.self)
        XCTAssertEqual(decoded.name, "张三")
        XCTAssertEqual(decoded.gender, "男")
    }
}
