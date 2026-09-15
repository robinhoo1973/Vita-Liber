import Foundation

public final class EncounterRepository: EncounterRepositoryProtocol {

    private let db: any DatabaseProtocol

    public init(db: any DatabaseProtocol) {
        self.db = db
    }

    public func save(_ card: EncounterRecord) async throws {
        guard !card.cardId.isEmpty else { throw RepositoryError.invalidId }
        try db.transaction {
            try db.execute("""
                INSERT INTO t_encounter
                (encounter_id, patient_id, visit_type, visit_date, department,
                 doctor_name, chief_complaint, diagnosis, treatment_plan, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(encounter_id) DO UPDATE SET
                    visit_type = excluded.visit_type, visit_date = excluded.visit_date,
                    department = excluded.department, doctor_name = excluded.doctor_name,
                    diagnosis = excluded.diagnosis;
                """, params: [
                    .text(card.cardId), .text(card.patientId ?? ""),
                    .text(card.visitType.rawValue),
                    .text(dateString(card.visitDate)),
                    card.department.map { .text($0) } ?? .null,
                    card.doctorName.map { .text($0) } ?? .null,
                    card.chiefComplaint.map { .text($0) } ?? .null,
                    card.diagnosis.map { .text($0) } ?? .null,
                    card.treatmentPlan.map { .text($0) } ?? .null,
                    .real(card.createdAt.timeIntervalSince1970)
                ])
        }
    }

    public func fetch(id: String) async throws -> EncounterRecord? {
        let rows = try db.query("SELECT * FROM t_encounter WHERE encounter_id = ? LIMIT 1;", params: [.text(id)])
        return rows.first.map(mapRow)
    }

    public func fetchAll(patientId: String) async throws -> [EncounterRecord] {
        let rows = try db.query("SELECT * FROM t_encounter WHERE patient_id = ? ORDER BY visit_date DESC;", params: [.text(patientId)])
        return rows.map(mapRow)
    }

    public func delete(id: String) async throws {
        try db.execute("DELETE FROM t_encounter WHERE encounter_id = ?;", params: [.text(id)])
    }

    private func mapRow(_ row: [String: SQLiteValue]) -> EncounterRecord {
        var card = EncounterRecord()
        card.cardId         = row["encounter_id"]?.string ?? UUID().uuidString
        card.patientId      = row["patient_id"]?.string
        card.visitType      = VisitType(rawValue: row["visit_type"]?.string ?? "初诊") ?? .firstVisit
        card.visitDate      = row["visit_date"]?.string.flatMap { dateFromString($0) } ?? Date()
        card.department     = row["department"]?.string
        card.doctorName     = row["doctor_name"]?.string
        card.chiefComplaint = row["chief_complaint"]?.string
        card.diagnosis      = row["diagnosis"]?.string
        card.treatmentPlan  = row["treatment_plan"]?.string
        card.createdAt      = row["created_at"]?.date ?? Date()
        return card
    }

    private func dateString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    private func dateFromString(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.date(from: s)
    }
}
