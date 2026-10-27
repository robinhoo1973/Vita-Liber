import Foundation
import GRDB
import Testing
@testable import Infrastructure

#if os(iOS) || os(macOS)
// linux-blind: GRDB 传输语义在 macOS CI 真跑（本文件自建最小表集，不依赖全量 schema）

@Suite("SU-M2-DOCEXPORT · 导出账本")
struct DocumentExportStoreTests {
    private func makeQueue() throws -> DatabaseQueue {
        // FK 必须在连接配置层开启：SQLite 对事务内的 PRAGMA foreign_keys 是
        // no-op，而在 write 闭包里执行该 PRAGMA 不会生效（级联断言会假红）。
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE document_file (
                  id TEXT PRIMARY KEY,
                  patient_id TEXT NOT NULL,
                  doc_type TEXT NOT NULL,
                  status TEXT NOT NULL DEFAULT 'active',
                  sha256 TEXT NOT NULL,
                  mime_type TEXT NOT NULL,
                  is_sensitive INTEGER NOT NULL DEFAULT 0,
                  origin TEXT NOT NULL,
                  created_at REAL NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE chat_conversation (
                  id TEXT PRIMARY KEY,
                  patient_id TEXT NOT NULL,
                  title TEXT NOT NULL,
                  pinned INTEGER NOT NULL DEFAULT 0,
                  created_at REAL NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE document_user_export (
                  document_id TEXT PRIMARY KEY REFERENCES document_file(id) ON DELETE CASCADE,
                  conversation_id TEXT REFERENCES chat_conversation(id) ON DELETE SET NULL,
                  directory_name TEXT NOT NULL,
                  display_name TEXT NOT NULL,
                  relative_path TEXT NOT NULL UNIQUE,
                  name_source TEXT NOT NULL CHECK(name_source IN ('auto','user','fallback')),
                  state TEXT NOT NULL DEFAULT 'active' CHECK(state IN ('active','missing','removed')),
                  size_bytes INTEGER,
                  mtime REAL,
                  created_at REAL NOT NULL,
                  updated_at REAL NOT NULL,
                  removed_at REAL);
                CREATE INDEX idx_document_user_export_conversation
                  ON document_user_export(conversation_id) WHERE removed_at IS NULL;
                """)
        }
        return queue
    }

    private func insertDocument(_ db: Database, id: UUID) throws {
        try db.execute(sql: """
            INSERT INTO document_file (id, patient_id, doc_type, sha256, mime_type, origin, created_at, updated_at)
            VALUES (?, 'p', 'record', 'sha:x', 'image/jpeg', 'import', 0, 0)
            """, arguments: [id.uuidString])
    }

    private func insertConversation(_ db: Database, id: UUID) throws {
        try db.execute(sql: """
            INSERT INTO chat_conversation (id, patient_id, title, created_at, updated_at)
            VALUES (?, 'p', '体检报告', 0, 0)
            """, arguments: [id.uuidString])
    }

    private func record(doc: UUID, conv: UUID?) -> DocumentExportStore.Record {
        DocumentExportStore.Record(
            documentID: doc, conversationID: conv,
            directoryName: "体检报告-abcdef", displayName: "检验报告-2026-10-01.jpg",
            relativePath: "体检报告-abcdef/检验报告-2026-10-01.jpg",
            nameSource: "auto", createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1))
    }

    @Test("upsert 幂等：同 document_id 二次写入覆盖而非重复行")
    func upsertIsIdempotent() async throws {
        let queue = try makeQueue()
        let doc = UUID(), conv = UUID()
        try await queue.write { try self.insertDocument($0, id: doc) }
        try await queue.write { try self.insertConversation($0, id: conv) }
        let store = DocumentExportStore(writer: queue)
        var first = try await store.upsert(record(doc: doc, conv: conv))
        first.displayName = "改名.jpg"
        first.relativePath = "体检报告-abcdef/改名.jpg"
        _ = try await store.upsert(first)
        let rows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document_user_export") ?? -1
        }
        #expect(rows == 1)
        let loaded = await store.record(documentID: doc)
        #expect(loaded?.displayName == "改名.jpg")
    }

    @Test("删文档行级联删账本；删会话只 SET NULL 保留副本行")
    func cascadeAndSetNull() async throws {
        let queue = try makeQueue()
        let doc = UUID(), conv = UUID()
        try await queue.write { try self.insertDocument($0, id: doc) }
        try await queue.write { try self.insertConversation($0, id: conv) }
        let store = DocumentExportStore(writer: queue)
        _ = try await store.upsert(record(doc: doc, conv: conv))
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM chat_conversation WHERE id = ?", arguments: [conv.uuidString])
        }
        let afterConv = await store.record(documentID: doc)
        #expect(afterConv != nil)
        #expect(afterConv?.conversationID == nil)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM document_file WHERE id = ?", arguments: [doc.uuidString])
        }
        #expect(await store.record(documentID: doc) == nil)
    }

    @Test("漂移态流转：missing→active 复位 removed_at；removed 记时间戳")
    func stateTransitions() async throws {
        let queue = try makeQueue()
        let doc = UUID()
        try await queue.write { try self.insertDocument($0, id: doc) }
        let store = DocumentExportStore(writer: queue)
        _ = try await store.upsert(record(doc: doc, conv: nil))
        try await store.setState(documentID: doc, state: "missing")
        #expect(await store.record(documentID: doc)?.state == "missing")
        #expect(await store.activeRecords().isEmpty)
        try await store.setState(documentID: doc, state: "active")
        #expect(await store.activeRecords().count == 1)
        try await store.setState(documentID: doc, state: "removed")
        let removed = await store.record(documentID: doc)
        #expect(removed?.removedAt != nil)
        #expect(await store.activeRecords().isEmpty)
    }
}
#endif
