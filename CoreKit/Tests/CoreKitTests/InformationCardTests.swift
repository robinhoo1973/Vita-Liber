import Testing
@testable import Domain

@Suite("InformationCard 信封协议")
struct InformationCardTests {

    @Test("PatientRecord 满足 InformationCard 契约")
    func patientRecordConforms() {
        var record = PatientRecord()
        record.name = "张三"
        #expect(PatientRecord.cardType == "patient")
        #expect(PatientRecord.schemaVersion == 1)
        #expect(!record.cardId.isEmpty)
    }

    @Test("ClinicalReport 满足 InformationCard 契约")
    func clinicalReportConforms() {
        var report = ClinicalReport()
        report.patientName = "李四"
        #expect(ClinicalReport.cardType == "clinical_report")
        #expect(!report.cardId.isEmpty)
    }
}
