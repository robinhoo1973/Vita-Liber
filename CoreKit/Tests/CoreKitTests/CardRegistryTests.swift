import XCTest
@testable import Domain

final class CardRegistryTests: XCTestCase {

    func testRegisterAndDecode() throws {
        let registry = CardRegistry()
        registry.register(PatientRecord.self)

        var record = PatientRecord()
        record.name = "王五"
        let data = try JSONEncoder.iso8601.encode(record)

        let card = try registry.decode(cardType: "patient", payload: data)
        let decoded = try card.decode(as: PatientRecord.self)
        XCTAssertEqual(decoded.name, "王五")
    }

    func testDecodeUnknownTypeThrows() {
        let registry = CardRegistry()
        let data = Data()

        XCTAssertThrowsError(try registry.decode(cardType: "unknown", payload: data)) { error in
            guard case CardError.unknownCardType = error else {
                return XCTFail("Expected unknownCardType error")
            }
        }
    }
}
