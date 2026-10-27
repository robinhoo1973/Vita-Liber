#if os(iOS) || os(macOS)
// linux-blind: GRDB 平台依赖；macOS CI 真跑（自建最小表集）
// 守卫必须包住 import：Linux 没有 GRDB 模块，守卫外的 import 会直接编译失败。
import Foundation
import GRDB
import Testing
@testable import Infrastructure

/// 聊天记录逐条敏感开关（2026-10-28 业主）：`DocumentStore.setSensitive` 契约。
@Suite("SU-M2-DOCEXPORT · 记录敏感开关")
struct DocumentSensitivityTests {
    private func makeQueue() throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE patient_profile (
                  id TEXT PRIMARY KEY, display_name TEXT NOT NULL, relation TEXT NOT NULL,
                  deleted_at REAL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE document_file (
                  id TEXT PRIMARY KEY,
                  patient_id TEXT NOT NULL REFERENCES patient_profile(id),
                  doc_type TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'active',
                  sha256 TEXT NOT NULL, mime_type TEXT NOT NULL,
                  is_sensitive INTEGER NOT NULL DEFAULT 0, origin TEXT NOT NULL,
                  created_at REAL NOT NULL, updated_at REAL NOT NULL);
                """)
        }
        return queue
    }

    private func insertPatient(_ db: Database, id: UUID, deleted: Bool = false) throws {
        try db.execute(sql: """
            INSERT INTO patient_profile VALUES (?, '王女士', 'self', ?, 0, 0)
            """, arguments: [id.uuidString, deleted ? 1.0 : nil])
    }

    private func insertDocument(_ db: Database, id: UUID, patient: UUID,
                                sensitive: Bool, status: String = "active") throws {
        try db.execute(sql: """
            INSERT INTO document_file
                (id, patient_id, doc_type, status, sha256, mime_type, is_sensitive, origin, created_at, updated_at)
            VALUES (?, ?, 'record', ?, 'sha:x', 'image/jpeg', ?, 'import', 0, 0)
            """, arguments: [id.uuidString, patient.uuidString, status, sensitive ? 1 : 0])
    }

    @Test("开→关→开 往返只改标记，其他列不动")
    func setSensitiveRoundtrip() async throws {
        let queue = try makeQueue()
        let patient = UUID(), doc = UUID()
        try await queue.write { db in
            try self.insertPatient(db, id: patient)
            try self.insertDocument(db, id: doc, patient: patient, sensitive: true)
        }
        let store = DocumentStore(writer: queue)
        try await store.setSensitive(id: doc, patientId: patient, sensitive: false)
        #expect(await store.fetch(id: doc)?.isSensitive == false)
        try await store.setSensitive(id: doc, patientId: patient, sensitive: true)
        #expect(await store.fetch(id: doc)?.isSensitive == true)
        // 未触碰内容列
        let row = await store.fetch(id: doc)
        #expect(row?.docType == "record")
        #expect(row?.status == "active")
    }

    @Test("未知文档/未知成员/软删成员一律拒绝且不改行")
    func rejectsInvalidTargets() async throws {
        let queue = try makeQueue()
        let patient = UUID(), doc = UUID(), gone = UUID()
        try await queue.write { db in
            try self.insertPatient(db, id: patient)
            try self.insertPatient(db, id: gone, deleted: true)
            try self.insertDocument(db, id: doc, patient: patient, sensitive: true)
        }
        let store = DocumentStore(writer: queue)
        await #expect(throws: (any Error).self) {
            try await store.setSensitive(id: UUID(), patientId: patient, sensitive: false)
        }
        await #expect(throws: (any Error).self) {
            try await store.setSensitive(id: doc, patientId: UUID(), sensitive: false)
        }
        await #expect(throws: (any Error).self) {
            try await store.setSensitive(id: doc, patientId: gone, sensitive: false)
        }
        #expect(await store.fetch(id: doc)?.isSensitive == true)
    }

    @Test("归档/已删文档不可改标记（只认 active/favorite）")
    func rejectsArchivedDocument() async throws {
        let queue = try makeQueue()
        let patient = UUID(), doc = UUID()
        try await queue.write { db in
            try self.insertPatient(db, id: patient)
            try self.insertDocument(db, id: doc, patient: patient, sensitive: true, status: "archived")
        }
        let store = DocumentStore(writer: queue)
        await #expect(throws: (any Error).self) {
            try await store.setSensitive(id: doc, patientId: patient, sensitive: false)
        }
        #expect(await store.fetch(id: doc)?.isSensitive == true)
    }
}
#endif
