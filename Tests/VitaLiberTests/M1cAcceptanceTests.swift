import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

/// TC-M1c 时间轴投影与全文搜索（test-plan §4.4）——GRDB 落库级断言
@MainActor
final class M1cAcceptanceTests: XCTestCase {

    private func makeStore() async throws -> GRDBStore {
        let store = try GRDBStore.inMemory()
        // 种子：成员 + 就诊 + 观察 + 指标
        let member = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, '测试患者', '本人', 0, 0)
                """, arguments: [member.uuidString])
            try db.execute(sql: """
                INSERT INTO encounter (id, patient_id, date, kind, diagnosis_text, created_at, updated_at)
                VALUES (?, ?, ?, '门诊', '上呼吸道感染', ?, ?)
                """, arguments: [UUID().uuidString, member.uuidString,
                                 Date().timeIntervalSince1970 - 86400,
                                 Date().timeIntervalSince1970, Date().timeIntervalSince1970])
            try db.execute(sql: """
                INSERT INTO observation (id, patient_id, kind, occurred_at, description, created_at, updated_at)
                VALUES (?, ?, 'skin', ?, '红疹', ?, ?)
                """, arguments: [UUID().uuidString, member.uuidString,
                                 Date().timeIntervalSince1970 - 3600,
                                 Date().timeIntervalSince1970, Date().timeIntervalSince1970])
        }
        return store
    }

    /// F11 时间轴联合投影：就诊+观察同轴、时间倒序、成员隔离
    func test_时间轴联合投影与隔离() async throws {
        let store = try await makeStore()
        let timeline = TimelineQueryStore(writer: store.writer)
        let member = try await store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM patient_profile LIMIT 1") ?? ""
        }
        let page = try await timeline.entries(for: UUID(uuidString: member) ?? UUID())
        XCTAssertEqual(page.entries.count, 2)
        // 时间倒序：观察（1h 前）先于就诊（1 天前）
        XCTAssertEqual(page.entries[0].kind, .observation)
        XCTAssertEqual(page.entries[1].kind, .encounter)
        // 成员隔离：其他成员查不到
        let other = try await timeline.entries(for: UUID())
        XCTAssertTrue(other.entries.isEmpty, "BR-001：跨成员查询必须为空")
    }

    /// F12 搜索：trigram 路由 + 2-gram 路由命中（FTS 双表索引同步）
    func test_搜索双路由命中() async throws {
        let store = try await makeStore()
        let search = GRDBSearchService(writer: store.writer)
        let docId = UUID()
        let member = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO document_file (id, patient_id, doc_type, sha256, mime_type, origin, meta_json, created_at, updated_at)
                VALUES (?, ?, 'prescription', ?, 'application/json', 'scanner', '{}', ?, ?)
                """, arguments: [docId.uuidString, member.uuidString, "sha-\(docId.uuidString)",
                                 Date().timeIntervalSince1970, Date().timeIntervalSince1970])
        }
        // 写入侧双表索引（trigram 主表 + 2-gram 影子）
        try await search.index(docID: docId, patientId: member, title: "空腹血糖记录",
                               ocrText: "空腹血糖 6.2 mmol/L", notes: nil)
        // ≥3 字 trigram
        let hits3 = try await search.search("空腹血糖", scope: .init(patientIds: [member]), limit: 10)
        XCTAssertTrue(hits3.contains { $0.refID == docId }, "trigram 主表必须命中")
        // 2 字 bigram
        let hits2 = try await search.search("血糖", scope: .init(patientIds: [member]), limit: 10)
        XCTAssertTrue(hits2.contains { $0.refID == docId }, "2-gram 影子表必须命中（短查询路由）")
        // 1 字 LIKE 兜底
        let hits1 = try await search.search("糖", scope: .init(patientIds: [member]), limit: 10)
        XCTAssertTrue(hits1.contains { $0.refID == docId }, "1 字 LIKE 兜底必须命中")
    }
}
