import XCTest
@testable import Infrastructure
@testable import Domain
@testable import Protocols

final class CardServiceIntegrationTests: XCTestCase {

    func testSaveAndFetchPatient() async throws {
        let db = try DatabaseFactory.makeInMemory()
        try db.execute("""
            CREATE TABLE t_patient (
                patient_id TEXT PRIMARY KEY,
                name TEXT NOT NULL DEFAULT '',
                gender TEXT NOT NULL DEFAULT '未知',
                birth_date REAL,
                id_number TEXT,
                health_card_no TEXT,
                phone TEXT,
                ethnicity TEXT,
                allergy_history TEXT NOT NULL DEFAULT '无',
                abo_blood_type TEXT,
                rh_blood_type TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
        try db.execute("""
            CREATE TABLE t_encounter (
                encounter_id TEXT PRIMARY KEY,
                patient_id TEXT NOT NULL DEFAULT '',
                visit_type TEXT NOT NULL DEFAULT '初诊',
                visit_date TEXT,
                department TEXT,
                doctor_name TEXT,
                chief_complaint TEXT,
                diagnosis TEXT,
                treatment_plan TEXT,
                created_at REAL NOT NULL
            );
            """)
        try db.execute("""
            CREATE TABLE t_clinical_report (
                report_id TEXT PRIMARY KEY,
                report_no TEXT,
                report_source TEXT NOT NULL DEFAULT '1',
                report_type TEXT NOT NULL DEFAULT '1',
                org_name TEXT,
                patient_id TEXT NOT NULL DEFAULT '',
                patient_name TEXT,
                gender TEXT,
                age TEXT,
                report_doctor TEXT,
                review_doctor TEXT,
                report_date TEXT,
                clinical_diagnosis TEXT,
                overall_conclusion TEXT,
                critical_flag INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
        try db.execute("""
            CREATE TABLE t_clinical_report_item (
                item_id TEXT PRIMARY KEY,
                report_id TEXT NOT NULL,
                item_category TEXT NOT NULL DEFAULT '检验',
                item_type TEXT NOT NULL DEFAULT '1',
                item_code TEXT,
                item_name TEXT NOT NULL,
                result_value TEXT,
                result_unit TEXT,
                reference_range TEXT,
                abnormal_flag TEXT,
                item_seq INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            );
            """)
        try db.execute("""
            CREATE TABLE t_clinical_report_conclusion (
                conclusion_id TEXT PRIMARY KEY,
                report_id TEXT NOT NULL,
                conclusion_type TEXT NOT NULL,
                conclusion_content TEXT NOT NULL,
                severity_level TEXT,
                seq_no INTEGER NOT NULL DEFAULT 0
            );
            """)
        try db.execute("""
            CREATE TABLE t_medication_schedule (
                schedule_id TEXT PRIMARY KEY,
                patient_id TEXT NOT NULL DEFAULT '',
                prescription_id TEXT,
                plan_name TEXT,
                plan_start_date REAL NOT NULL,
                plan_end_date REAL,
                remind_method TEXT,
                status TEXT NOT NULL DEFAULT '0',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
        try db.execute("""
            CREATE TABLE t_appointment (
                appointment_id TEXT PRIMARY KEY,
                patient_id TEXT NOT NULL DEFAULT '',
                appointment_type TEXT NOT NULL DEFAULT '1',
                department TEXT,
                doctor_name TEXT,
                appointment_date REAL NOT NULL,
                appointment_time TEXT NOT NULL DEFAULT '',
                appointment_location TEXT,
                status TEXT NOT NULL DEFAULT '0',
                cancel_reason TEXT,
                encounter_id TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """)

        let patientRepo = PatientRepository(db: db)
        let encounterRepo = EncounterRepository(db: db)
        let reportRepo = ClinicalReportRepository(db: db)
        let medScheduleRepo = MedicationScheduleRepository(db: db)
        let appointmentRepo = AppointmentRepository(db: db)
        let engine = StubTextUnderstanding()

        let cardService = CardService(
            patientRepo: patientRepo,
            encounterRepo: encounterRepo,
            reportRepo: reportRepo,
            medScheduleRepo: medScheduleRepo,
            appointmentRepo: appointmentRepo,
            engine: engine
        )

        var card = PatientRecord()
        card.name = "测试患者"
        card.gender = "男"
        try await cardService.savePatient(card)

        let fetched = try await cardService.fetchPatient(id: card.cardId)
        XCTAssertEqual(fetched?.name, "测试患者")
    }
}
