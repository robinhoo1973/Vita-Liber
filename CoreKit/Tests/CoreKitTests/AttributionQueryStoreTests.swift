#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Testing
@testable import Domain
@testable import Infrastructure

@Suite("Attribution query store")
struct AttributionQueryStoreTests {
    private func date(_ day: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return c.date(from: DateComponents(year: 2026, month: 3, day: day, hour: 9)) ?? Date()
    }

    @Test("collects confirmed orphan prescriptions and maps encounter candidates")
    func collectsOrphanAndEncounter() async throws {
        let db = try DatabaseQueue()
        let patient = UUID()
        let encounter = UUID()
        let prescription = UUID()
        try await db.write { db in
            try db.execute(sql: """
                CREATE TABLE encounter (id TEXT, patient_id TEXT, date REAL, kind TEXT,
                  hospital TEXT, department TEXT, doctor TEXT, deleted_at REAL);
                CREATE TABLE hospitalization (encounter_id TEXT, admit_at REAL, discharge_at REAL);
                CREATE TABLE document_file (id TEXT, sha256 TEXT);
                CREATE TABLE prescription (id TEXT, patient_id TEXT, encounter_id TEXT,
                  confirmed INTEGER, prescribed_at REAL, hospital TEXT, department TEXT,
                  doctor TEXT, document_file_id TEXT);
                CREATE TABLE lab_report (id TEXT, patient_id TEXT, encounter_id TEXT,
                  confirmed INTEGER, collected_at REAL, reported_at REAL, hospital TEXT,
                  department TEXT, send_doctor TEXT, review_doctor TEXT, document_file_id TEXT);
                CREATE TABLE exam_report (id TEXT, patient_id TEXT, encounter_id TEXT,
                  confirmed INTEGER, exam_at REAL, reported_at REAL, hospital TEXT,
                  department TEXT, apply_doctor TEXT, document_file_id TEXT);
                CREATE TABLE surgery (id TEXT, patient_id TEXT, encounter_id TEXT,
                  confirmed INTEGER, surgery_at REAL, hospital TEXT, department TEXT,
                  surgeon TEXT, document_file_id TEXT);
                CREATE TABLE treatment_record (id TEXT, patient_id TEXT, encounter_id TEXT,
                  confirmed INTEGER, treated_at REAL, hospital TEXT, department TEXT,
                  doctor TEXT, document_file_id TEXT);
                """)
            try db.execute(sql: """
                INSERT INTO encounter (id, patient_id, date, kind, hospital, department, doctor, deleted_at)
                VALUES (?, ?, ?, 'outpatient', '市第一医院', '心内科', '王医生', NULL)
                """, arguments: [encounter.uuidString, patient.uuidString, date(5).timeIntervalSince1970])
            try db.execute(sql: """
                INSERT INTO prescription (id, patient_id, encounter_id, confirmed, prescribed_at,
                  hospital, department, doctor, document_file_id)
                VALUES (?, ?, NULL, 1, ?, '市第一医院', '心内科', '王医生', NULL)
                """, arguments: [prescription.uuidString, patient.uuidString,
                                 date(5).timeIntervalSince1970])
        }

        let store = AttributionQueryStore(writer: db)
        let out = try await store.suggestions(patientId: patient, now: date(10))
        #expect(out.count == 1)
        #expect(out.first?.orphan.entityId == prescription)
        #expect(out.first?.encounterId == encounter)
    }

    @Test("orphan with different hospital is withheld")
    func differentHospitalWithheld() async throws {
        let db = try DatabaseQueue()
        let patient = UUID()
        try await db.write { db in
            try db.execute(sql: """
                CREATE TABLE encounter (id TEXT, patient_id TEXT, date REAL, kind TEXT,
                  hospital TEXT, department TEXT, doctor TEXT, deleted_at REAL);
                CREATE TABLE hospitalization (encounter_id TEXT, admit_at REAL, discharge_at REAL);
                CREATE TABLE document_file (id TEXT, sha256 TEXT);
                CREATE TABLE prescription (id TEXT, patient_id TEXT, encounter_id TEXT,
                  confirmed INTEGER, prescribed_at REAL, hospital TEXT, department TEXT,
                  doctor TEXT, document_file_id TEXT);
                CREATE TABLE lab_report (id TEXT, patient_id TEXT, encounter_id TEXT,
                  confirmed INTEGER, collected_at REAL, reported_at REAL, hospital TEXT,
                  department TEXT, send_doctor TEXT, review_doctor TEXT, document_file_id TEXT);
                CREATE TABLE exam_report (id TEXT, patient_id TEXT, encounter_id TEXT,
                  confirmed INTEGER, exam_at REAL, reported_at REAL, hospital TEXT,
                  department TEXT, apply_doctor TEXT, document_file_id TEXT);
                CREATE TABLE surgery (id TEXT, patient_id TEXT, encounter_id TEXT,
                  confirmed INTEGER, surgery_at REAL, hospital TEXT, department TEXT,
                  surgeon TEXT, document_file_id TEXT);
                CREATE TABLE treatment_record (id TEXT, patient_id TEXT, encounter_id TEXT,
                  confirmed INTEGER, treated_at REAL, hospital TEXT, department TEXT,
                  doctor TEXT, document_file_id TEXT);
                """)
            try db.execute(sql: """
                INSERT INTO encounter (id, patient_id, date, kind, hospital, department, doctor, deleted_at)
                VALUES (?, ?, ?, 'outpatient', '市第一医院', '心内科', '王医生', NULL)
                """, arguments: [UUID().uuidString, patient.uuidString, date(5).timeIntervalSince1970])
            try db.execute(sql: """
                INSERT INTO prescription (id, patient_id, encounter_id, confirmed, prescribed_at,
                  hospital, department, doctor, document_file_id)
                VALUES (?, ?, NULL, 1, ?, '市第二医院', '心内科', '王医生', NULL)
                """, arguments: [UUID().uuidString, patient.uuidString, date(5).timeIntervalSince1970])
        }
        let out = try await AttributionQueryStore(writer: db)
            .suggestions(patientId: patient, now: date(10))
        #expect(out.isEmpty)
    }
}
#endif
