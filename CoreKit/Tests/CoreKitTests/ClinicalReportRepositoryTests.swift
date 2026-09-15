import XCTest
@testable import Infrastructure
@testable import Domain
@testable import Protocols

final class ClinicalReportRepositoryTests: XCTestCase {

    var db: (any DatabaseProtocol)!
    var repo: ClinicalReportRepository!

    override func setUp() async throws {
        db = try DatabaseFactory.makeInMemory()
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
        repo = ClinicalReportRepository(db: db)
    }

    func testSaveAndFetch() async throws {
        var card = ClinicalReport()
        card.cardId = "r1"
        card.patientId = "p1"
        card.patientName = "张三"
        card.orgName = "某医院"
        card.items = [
            ClinicalReportItem(name: "白细胞计数", value: "6.5", unit: "10^9/L", referenceRange: "4.0-10.0")
        ]

        try await repo.save(card)

        let fetched = try await repo.fetch(id: "r1")
        XCTAssertEqual(fetched?.patientName, "张三")
        XCTAssertEqual(fetched?.items.count, 1)
        XCTAssertEqual(fetched?.items.first?.name, "白细胞计数")
    }

    func testDelete() async throws {
        var card = ClinicalReport(); card.cardId = "r1"
        try await repo.save(card)
        try await repo.delete(id: "r1")

        let fetched = try await repo.fetch(id: "r1")
        XCTAssertNil(fetched)
    }
}
