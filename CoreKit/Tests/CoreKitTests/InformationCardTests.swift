import XCTest
@testable import Domain

final class InformationCardTests: XCTestCase {

    func testPatientRecordConformsToInformationCard() {
        var record = PatientRecord()
        record.name = "张三"
        XCTAssertEqual(PatientRecord.cardType, "patient")
        XCTAssertEqual(PatientRecord.schemaVersion, 1)
        XCTAssertFalse(record.cardId.isEmpty)
    }

    func testClinicalReportConformsToInformationCard() {
        var report = ClinicalReport()
        report.patientName = "李四"
        XCTAssertEqual(ClinicalReport.cardType, "clinical_report")
        XCTAssertFalse(report.cardId.isEmpty)
    }
}
