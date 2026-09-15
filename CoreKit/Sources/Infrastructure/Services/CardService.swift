import Foundation
import Domain
import Protocols

public protocol CardServiceProtocol: Sendable {
    func ingest(text: String, context: TextUnderstandingInput) async throws -> [AnyCard]
    func savePatient(_ card: PatientRecord) async throws
    func saveEncounter(_ card: EncounterRecord) async throws
    func saveReport(_ card: ClinicalReport) async throws
    func saveMedicationSchedule(_ card: MedicationSchedule) async throws
    func saveAppointment(_ card: AppointmentRecord) async throws
    func fetchPatient(id: String) async throws -> PatientRecord?
    func fetchReports(patientId: String) async throws -> [ClinicalReport]
    func fetchEncounters(patientId: String) async throws -> [EncounterRecord]
    func fetchUpcomingAppointments(patientId: String) async throws -> [AppointmentRecord]
}

public final class CardService: CardServiceProtocol {

    private let patientRepo: any PatientRepositoryProtocol
    private let encounterRepo: any EncounterRepositoryProtocol
    private let reportRepo: any ClinicalReportRepositoryProtocol
    private let medScheduleRepo: any MedicationScheduleRepositoryProtocol
    private let appointmentRepo: any AppointmentRepositoryProtocol
    private let engine: any TextUnderstanding

    public init(
        patientRepo: any PatientRepositoryProtocol,
        encounterRepo: any EncounterRepositoryProtocol,
        reportRepo: any ClinicalReportRepositoryProtocol,
        medScheduleRepo: any MedicationScheduleRepositoryProtocol,
        appointmentRepo: any AppointmentRepositoryProtocol,
        engine: any TextUnderstanding
    ) {
        self.patientRepo = patientRepo
        self.encounterRepo = encounterRepo
        self.reportRepo = reportRepo
        self.medScheduleRepo = medScheduleRepo
        self.appointmentRepo = appointmentRepo
        self.engine = engine
    }

    public func ingest(text: String, context: TextUnderstandingInput) async throws -> [AnyCard] {
        let result = await engine.understand(context)
        var persisted: [AnyCard] = []
        for field in result.fields {
            if let card = try? fieldToCard(field) {
                try await persist(card)
                persisted.append(card)
            }
        }
        return persisted
    }

    private func fieldToCard(_ field: FieldDraft) throws -> AnyCard {
        switch field.key {
        case "name", "gender", "birth_date", "id_number":
            var card = PatientRecord()
            card.rawText = field.rawText
            return try AnyCard(card)
        case "department", "diagnosis":
            var card = EncounterRecord()
            card.rawText = field.rawText
            return try AnyCard(card)
        case "lab_item", "report_type":
            var card = ClinicalReport()
            card.rawText = field.rawText
            return try AnyCard(card)
        case "drug_name", "dosage":
            var card = MedicationSchedule()
            card.rawText = field.rawText
            return try AnyCard(card)
        case "appointment_date", "appointment_time":
            var card = AppointmentRecord()
            card.rawText = field.rawText
            return try AnyCard(card)
        default:
            var card = ClinicalReport()
            card.rawText = field.rawText
            return try AnyCard(card)
        }
    }

    private func persist(_ anyCard: AnyCard) async throws {
        switch anyCard.cardType {
        case PatientRecord.cardType:
            try await patientRepo.save(try anyCard.decode(as: PatientRecord.self))
        case EncounterRecord.cardType:
            try await encounterRepo.save(try anyCard.decode(as: EncounterRecord.self))
        case ClinicalReport.cardType:
            try await reportRepo.save(try anyCard.decode(as: ClinicalReport.self))
        case MedicationSchedule.cardType:
            try await medScheduleRepo.save(try anyCard.decode(as: MedicationSchedule.self))
        case AppointmentRecord.cardType:
            try await appointmentRepo.save(try anyCard.decode(as: AppointmentRecord.self))
        default:
            break
        }
    }

    public func savePatient(_ card: PatientRecord) async throws { try await patientRepo.save(card) }
    public func saveEncounter(_ card: EncounterRecord) async throws { try await encounterRepo.save(card) }
    public func saveReport(_ card: ClinicalReport) async throws { try await reportRepo.save(card) }
    public func saveMedicationSchedule(_ card: MedicationSchedule) async throws { try await medScheduleRepo.save(card) }
    public func saveAppointment(_ card: AppointmentRecord) async throws { try await appointmentRepo.save(card) }

    public func fetchPatient(id: String) async throws -> PatientRecord? { try await patientRepo.fetch(id: id) }
    public func fetchReports(patientId: String) async throws -> [ClinicalReport] { try await reportRepo.fetchAll(patientId: patientId) }
    public func fetchEncounters(patientId: String) async throws -> [EncounterRecord] { try await encounterRepo.fetchAll(patientId: patientId) }
    public func fetchUpcomingAppointments(patientId: String) async throws -> [AppointmentRecord] { try await appointmentRepo.fetchUpcoming(patientId: patientId, from: Date()) }
}

public final class MedicationScheduleRepository: MedicationScheduleRepositoryProtocol {

    private let db: any DatabaseProtocol

    public init(db: any DatabaseProtocol) {
        self.db = db
    }

    public func save(_ card: MedicationSchedule) async throws {
        guard !card.cardId.isEmpty else { throw RepositoryError.invalidId }
        try db.transaction {
            try db.execute("""
                INSERT INTO t_medication_schedule
                (schedule_id, patient_id, prescription_id, plan_name, plan_start_date,
                 plan_end_date, remind_method, status, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(schedule_id) DO UPDATE SET
                    plan_name = excluded.plan_name, status = excluded.status,
                    updated_at = excluded.updated_at;
                """, params: [
                    .text(card.cardId),
                    .text(card.patientId ?? ""),
                    card.prescriptionId.map { .text($0) } ?? .null,
                    card.planName.map { .text($0) } ?? .null,
                    .real(card.planStartDate.timeIntervalSince1970),
                    card.planEndDate.map { .real($0.timeIntervalSince1970) } ?? .null,
                    card.remindMethod.map { .text($0) } ?? .null,
                    .text(card.status.rawValue),
                    .real(card.createdAt.timeIntervalSince1970),
                    .real(card.updatedAt.timeIntervalSince1970)
                ])
        }
    }

    public func fetch(id: String) async throws -> MedicationSchedule? {
        let rows = try db.query("SELECT * FROM t_medication_schedule WHERE schedule_id = ? LIMIT 1;", params: [.text(id)])
        return rows.first.map(mapRow)
    }

    public func fetchActive(patientId: String) async throws -> [MedicationSchedule] {
        let rows = try db.query("SELECT * FROM t_medication_schedule WHERE patient_id = ? AND status = '0' ORDER BY plan_start_date DESC;", params: [.text(patientId)])
        return rows.map(mapRow)
    }

    public func delete(id: String) async throws {
        try db.execute("DELETE FROM t_medication_schedule WHERE schedule_id = ?;", params: [.text(id)])
    }

    private func mapRow(_ row: [String: SQLiteValue]) -> MedicationSchedule {
        var card = MedicationSchedule()
        card.cardId        = row["schedule_id"]?.string ?? UUID().uuidString
        card.patientId     = row["patient_id"]?.string
        card.prescriptionId = row["prescription_id"]?.string
        card.planName      = row["plan_name"]?.string
        card.planStartDate = row["plan_start_date"]?.date ?? Date()
        card.planEndDate   = row["plan_end_date"]?.date
        card.remindMethod  = row["remind_method"]?.string
        card.status        = ScheduleStatus(rawValue: row["status"]?.string ?? "0") ?? .active
        card.createdAt     = row["created_at"]?.date ?? Date()
        card.updatedAt     = row["updated_at"]?.date ?? card.createdAt
        return card
    }
}

public final class AppointmentRepository: AppointmentRepositoryProtocol {

    private let db: any DatabaseProtocol

    public init(db: any DatabaseProtocol) {
        self.db = db
    }

    public func save(_ card: AppointmentRecord) async throws {
        guard !card.cardId.isEmpty else { throw RepositoryError.invalidId }
        try db.transaction {
            try db.execute("""
                INSERT INTO t_appointment
                (appointment_id, patient_id, appointment_type, department, doctor_name,
                 appointment_date, appointment_time, appointment_location, status,
                 cancel_reason, encounter_id, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(appointment_id) DO UPDATE SET
                    status = excluded.status, updated_at = excluded.updated_at;
                """, params: [
                    .text(card.cardId),
                    .text(card.patientId ?? ""),
                    .text(card.appointmentType.rawValue),
                    card.department.map { .text($0) } ?? .null,
                    card.doctorName.map { .text($0) } ?? .null,
                    .real(card.appointmentDate.timeIntervalSince1970),
                    .text(card.appointmentTime),
                    card.appointmentLocation.map { .text($0) } ?? .null,
                    .text(card.status.rawValue),
                    card.cancelReason.map { .text($0) } ?? .null,
                    card.encounterId.map { .text($0) } ?? .null,
                    .real(card.createdAt.timeIntervalSince1970),
                    .real(card.updatedAt.timeIntervalSince1970)
                ])
        }
    }

    public func fetch(id: String) async throws -> AppointmentRecord? {
        let rows = try db.query("SELECT * FROM t_appointment WHERE appointment_id = ? LIMIT 1;", params: [.text(id)])
        return rows.first.map(mapRow)
    }

    public func fetchUpcoming(patientId: String, from: Date) async throws -> [AppointmentRecord] {
        let rows = try db.query("SELECT * FROM t_appointment WHERE patient_id = ? AND appointment_date >= ? ORDER BY appointment_date ASC;", params: [.text(patientId), .real(from.timeIntervalSince1970)])
        return rows.map(mapRow)
    }

    public func delete(id: String) async throws {
        try db.execute("DELETE FROM t_appointment WHERE appointment_id = ?;", params: [.text(id)])
    }

    private func mapRow(_ row: [String: SQLiteValue]) -> AppointmentRecord {
        var card = AppointmentRecord()
        card.cardId              = row["appointment_id"]?.string ?? UUID().uuidString
        card.patientId           = row["patient_id"]?.string
        card.appointmentType     = AppointmentType(rawValue: row["appointment_type"]?.string ?? "1") ?? .visit
        card.department          = row["department"]?.string
        card.doctorName          = row["doctor_name"]?.string
        card.appointmentDate     = row["appointment_date"]?.date ?? Date()
        card.appointmentTime     = row["appointment_time"]?.string ?? ""
        card.appointmentLocation = row["appointment_location"]?.string
        card.status              = AppointmentStatus(rawValue: row["status"]?.string ?? "0") ?? .booked
        card.cancelReason        = row["cancel_reason"]?.string
        card.encounterId         = row["encounter_id"]?.string
        card.createdAt           = row["created_at"]?.date ?? Date()
        card.updatedAt           = row["updated_at"]?.date ?? card.createdAt
        return card
    }
}
