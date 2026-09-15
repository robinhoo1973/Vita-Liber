import Foundation

public final class PatientRepository: PatientRepositoryProtocol {

    private let db: any DatabaseProtocol

    public init(db: any DatabaseProtocol) {
        self.db = db
    }

    public func save(_ card: PatientRecord) async throws {
        guard !card.cardId.isEmpty else { throw RepositoryError.invalidId }
        try db.transaction {
            try db.execute("""
                INSERT INTO t_patient
                (patient_id, name, gender, birth_date, id_number, health_card_no,
                 phone, ethnicity, allergy_history, abo_blood_type, rh_blood_type,
                 created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(patient_id) DO UPDATE SET
                    name = excluded.name, gender = excluded.gender,
                    birth_date = excluded.birth_date, id_number = excluded.id_number,
                    phone = excluded.phone, allergy_history = excluded.allergy_history,
                    updated_at = excluded.updated_at;
                """, params: [
                    .text(card.cardId),
                    .text(card.name ?? ""),
                    .text(card.gender ?? "未知"),
                    card.birthDate.map { .real($0.timeIntervalSince1970) } ?? .null,
                    card.idNumber.map { .text($0) } ?? .null,
                    card.healthCardNo.map { .text($0) } ?? .null,
                    card.phone.map { .text($0) } ?? .null,
                    card.ethnicity.map { .text($0) } ?? .null,
                    .text(card.allergyHistory ?? "无"),
                    card.aboBloodType.map { .text($0) } ?? .null,
                    card.rhBloodType.map { .text($0) } ?? .null,
                    .real(card.createdAt.timeIntervalSince1970),
                    .real(card.updatedAt.timeIntervalSince1970)
                ])
        }
    }

    public func fetch(id: String) async throws -> PatientRecord? {
        let rows = try db.query("SELECT * FROM t_patient WHERE patient_id = ? LIMIT 1;", params: [.text(id)])
        return rows.first.map(mapRow)
    }

    public func fetchAll() async throws -> [PatientRecord] {
        let rows = try db.query("SELECT * FROM t_patient ORDER BY created_at DESC;")
        return rows.map(mapRow)
    }

    public func delete(id: String) async throws {
        try db.transaction {
            try db.execute("DELETE FROM t_patient WHERE patient_id = ?;", params: [.text(id)])
        }
    }

    public func exists(id: String) async throws -> Bool {
        let count: Int64? = try db.queryScalar("SELECT COUNT(1) FROM t_patient WHERE patient_id = ?;", params: [.text(id)])
        return (count ?? 0) > 0
    }

    private func mapRow(_ row: [String: SQLiteValue]) -> PatientRecord {
        var card = PatientRecord()
        card.cardId         = row["patient_id"]?.string ?? UUID().uuidString
        card.patientId      = card.cardId
        card.name           = row["name"]?.string
        card.gender         = row["gender"]?.string
        card.birthDate      = row["birth_date"]?.date
        card.idNumber       = row["id_number"]?.string
        card.healthCardNo   = row["health_card_no"]?.string
        card.phone          = row["phone"]?.string
        card.ethnicity      = row["ethnicity"]?.string
        card.allergyHistory = row["allergy_history"]?.string
        card.aboBloodType   = row["abo_blood_type"]?.string
        card.rhBloodType    = row["rh_blood_type"]?.string
        card.createdAt      = row["created_at"]?.date ?? Date()
        card.updatedAt      = row["updated_at"]?.date ?? card.createdAt
        return card
    }
}
