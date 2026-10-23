import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure

// binds: SU-M1c-REGRESSION（FR11.4 / SP-49）
/// `createMany` 多选保存：一次事务写入整批（同 `now`），空批不落行；
/// 外键/约束失败整体抛出——SP-49 三步流「任一失败不产生半批记录」的回归面。
@MainActor
final class HealthProblemStoreTests: XCTestCase {
    func test_createMany_persistsWholeBatchWithSharedTimestamp() async throws {
        let (dbStore, patient) = try await GRDBStore.inMemoryWithPatient()
        let store = HealthProblemStore(writer: dbStore.writer)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ids = try await store.createMany(patientId: patient, problems: [
            .init(name: "高血压", kind: "chronic", bodyRegion: "systemic", bodySite: nil, year: 2018),
            .init(name: "阑尾切除术", kind: "surgery", bodyRegion: "abdomen", bodySite: "intestine", year: 2012),
        ], now: now)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2, "每条记录独立 id")

        let rows = try await store.list(patientId: patient)
        XCTAssertEqual(Set(rows.map(\.name)), ["高血压", "阑尾切除术"])
        let surgery = try XCTUnwrap(rows.first { $0.name == "阑尾切除术" })
        XCTAssertEqual(surgery.kind, "surgery")
        XCTAssertEqual(surgery.bodyRegion, "abdomen")
        XCTAssertEqual(surgery.bodySite, "intestine")
        XCTAssertEqual(surgery.year, 2012)
        XCTAssertEqual(rows.first { $0.name == "高血压" }?.year, 2018)

        // 同批共享同一个 now（列表按 created_at 排序的前提）
        let stamps = try await dbStore.writer.read { db in
            try Double.fetchAll(db, sql: """
                SELECT created_at FROM health_problem WHERE patient_id = ?
                """, arguments: [patient.uuidString])
        }
        XCTAssertEqual(Set(stamps).count, 1)
        XCTAssertEqual(stamps.first, now.timeIntervalSince1970)
    }

    func test_createMany_emptyBatchWritesNothing() async throws {
        let (dbStore, patient) = try await GRDBStore.inMemoryWithPatient()
        let store = HealthProblemStore(writer: dbStore.writer)
        let ids = try await store.createMany(patientId: patient, problems: [])
        XCTAssertTrue(ids.isEmpty)
        let rows = try await store.list(patientId: patient)
        XCTAssertTrue(rows.isEmpty)
    }

    func test_createMany_unknownPatientThrows() async throws {
        let (dbStore, _) = try await GRDBStore.inMemoryWithPatient()
        let store = HealthProblemStore(writer: dbStore.writer)
        do {
            _ = try await store.createMany(patientId: UUID(), problems: [
                .init(name: "高血压", kind: "chronic", bodyRegion: nil, bodySite: nil),
            ])
            XCTFail("patient_profile 外键缺失须抛出")
        } catch {
            // 期望：foreign key 失败（ERR#35 纪律）
        }
    }
}
