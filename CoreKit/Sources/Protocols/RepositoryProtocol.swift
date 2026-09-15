import Foundation

public protocol PatientRepositoryProtocol: Sendable {
    func save(_ card: PatientRecord) async throws
    func fetch(id: String) async throws -> PatientRecord?
    func fetchAll() async throws -> [PatientRecord]
    func delete(id: String) async throws
    func exists(id: String) async throws -> Bool
}

public protocol EncounterRepositoryProtocol: Sendable {
    func save(_ card: EncounterRecord) async throws
    func fetch(id: String) async throws -> EncounterRecord?
    func fetchAll(patientId: String) async throws -> [EncounterRecord]
    func delete(id: String) async throws
}

public protocol ClinicalReportRepositoryProtocol: Sendable {
    func save(_ card: ClinicalReport) async throws
    func fetch(id: String) async throws -> ClinicalReport?
    func fetchAll(patientId: String?) async throws -> [ClinicalReport]
    func fetchItems(reportId: String) async throws -> [ReportItem]
    func delete(id: String) async throws
}

public protocol MedicationScheduleRepositoryProtocol: Sendable {
    func save(_ card: MedicationSchedule) async throws
    func fetch(id: String) async throws -> MedicationSchedule?
    func fetchActive(patientId: String) async throws -> [MedicationSchedule]
    func delete(id: String) async throws
}

public protocol MedicationGuideRepositoryProtocol: Sendable {
    func save(_ card: MedicationGuide) async throws
    func fetch(id: String) async throws -> MedicationGuide?
    func fetchByDrugCode(_ code: String) async throws -> [MedicationGuide]
    func delete(id: String) async throws
}

public protocol AppointmentRepositoryProtocol: Sendable {
    func save(_ card: AppointmentRecord) async throws
    func fetch(id: String) async throws -> AppointmentRecord?
    func fetchUpcoming(patientId: String, from: Date) async throws -> [AppointmentRecord]
    func delete(id: String) async throws
}
