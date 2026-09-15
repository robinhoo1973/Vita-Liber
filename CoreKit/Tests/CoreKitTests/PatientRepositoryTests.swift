import XCTest
@testable import Infrastructure
@testable import Domain
@testable import Protocols

final class PatientRepositoryTests: XCTestCase {

    var db: (any DatabaseProtocol)!
    var repo: PatientRepository!

    override func setUp() async throws {
        db = try DatabaseFactory.makeInMemory()
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
        repo = PatientRepository(db: db)
    }

    func testSaveAndFetch() async throws {
        var card = PatientRecord()
        card.cardId = "p1"
        card.name = "张三"
        card.gender = "男"
        card.allergyHistory = "青霉素"

        try await repo.save(card)

        let fetched = try await repo.fetch(id: "p1")
        XCTAssertEqual(fetched?.name, "张三")
        XCTAssertEqual(fetched?.allergyHistory, "青霉素")
    }

    func testFetchAll() async throws {
        var card1 = PatientRecord(); card1.cardId = "p1"; card1.name = "A"
        var card2 = PatientRecord(); card2.cardId = "p2"; card2.name = "B"
        try await repo.save(card1)
        try await repo.save(card2)

        let all = try await repo.fetchAll()
        XCTAssertEqual(all.count, 2)
    }

    func testDelete() async throws {
        var card = PatientRecord(); card.cardId = "p1"; card.name = "张三"
        try await repo.save(card)
        try await repo.delete(id: "p1")

        let fetched = try await repo.fetch(id: "p1")
        XCTAssertNil(fetched)
    }

    func testExists() async throws {
        var card = PatientRecord(); card.cardId = "p1"
        try await repo.save(card)

        XCTAssertTrue(try await repo.exists(id: "p1"))
        XCTAssertFalse(try await repo.exists(id: "p999"))
    }
}
