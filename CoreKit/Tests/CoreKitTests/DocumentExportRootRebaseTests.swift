#if os(iOS) || os(macOS)
// linux-blind: GRDB/FileManager 传输语义在 macOS CI 真跑；Linux 无 GRDB 模块。
import Foundation
import GRDB
import Testing
@testable import Infrastructure

/// 2026-11-02 真机：Files 二级根从通用「Vita Liber」回到 Documents 根。
/// 迁移按账本前缀驱动，必须覆盖：搬移、崩溃后补账、冲突跳过、空根清理。
@Suite("SU-M2-DOCEXPORT · 旧用户面根迁移")
struct DocumentExportRootRebaseTests {
    private struct Fixture {
        let root: URL
        let exports: URL
        let queue: DatabaseQueue
        let ledger: DocumentExportStore
        let mirror: DocumentExportMirror
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-rebase-\(UUID().uuidString)", isDirectory: true)
        let exports = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE document_file (
                  id TEXT PRIMARY KEY, patient_id TEXT NOT NULL, doc_type TEXT NOT NULL,
                  status TEXT NOT NULL DEFAULT 'active', sha256 TEXT NOT NULL,
                  mime_type TEXT NOT NULL, is_sensitive INTEGER NOT NULL DEFAULT 0,
                  origin TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE document_user_export (
                  document_id TEXT PRIMARY KEY REFERENCES document_file(id) ON DELETE CASCADE,
                  conversation_id TEXT,
                  directory_name TEXT NOT NULL, display_name TEXT NOT NULL,
                  relative_path TEXT NOT NULL UNIQUE,
                  name_source TEXT NOT NULL CHECK(name_source IN ('auto','user','fallback')),
                  state TEXT NOT NULL DEFAULT 'active' CHECK(state IN ('active','missing','removed')),
                  size_bytes INTEGER, mtime REAL,
                  created_at REAL NOT NULL, updated_at REAL NOT NULL, removed_at REAL);
                """)
        }
        let ledger = DocumentExportStore(writer: queue)
        let mirror = DocumentExportMirror(
            ledger: ledger, exportsBase: exports, originalsDir: root)
        return Fixture(root: root, exports: exports, queue: queue, ledger: ledger, mirror: mirror)
    }

    private func addDocumentAndRecord(_ f: Fixture, directory: String,
                                      fileName: String, conversationID: UUID? = nil) async throws {
        let documentID = UUID()
        try await f.queue.write { db in
            try db.execute(sql: """
                INSERT INTO document_file (id, patient_id, doc_type, sha256, mime_type, origin, created_at, updated_at)
                VALUES (?, 'p', 'record', 'sha:x', 'image/jpeg', 'import', 0, 0)
                """, arguments: [documentID.uuidString])
        }
        _ = try await f.ledger.upsert(.init(
            documentID: documentID, conversationID: conversationID,
            directoryName: directory, displayName: fileName,
            relativePath: "\(directory)/\(fileName)", nameSource: "auto",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)))
    }

    private func writeFile(_ url: URL, bytes: String = "x") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: url)
    }

    @Test("旧在、新不在：会话目录搬到 conversation/ 并改写账本")
    func movesLegacyDirectory() async throws {
        let f = try await makeFixture()
        let leaf = "20261102-1435-会话-abcdef"
        let old = f.exports.appendingPathComponent("Vita Liber/\(leaf)", isDirectory: true)
        try writeFile(old.appendingPathComponent("report.jpg"))
        try await addDocumentAndRecord(f, directory: "Vita Liber/\(leaf)", fileName: "report.jpg",
                                       conversationID: UUID())

        let changed = await f.mirror.migrateLegacyExportRootIfNeeded()
        #expect(changed)
        let new = f.exports.appendingPathComponent("conversation/\(leaf)", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("report.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        let row = await f.ledger.records(directoryName: "conversation/\(leaf)").first
        #expect(row?.relativePath == "conversation/\(leaf)/report.jpg")
        #expect(!FileManager.default.fileExists(atPath: f.exports.appendingPathComponent("Vita Liber").path),
                "空的旧根应删除")
    }

    @Test("旧不在、新在：校验文件后补账，不认领用户自建空目录")
    func completesInterruptedMove() async throws {
        let f = try await makeFixture()
        let leaf = "20261102-1435-会话-abcdef"
        try writeFile(f.exports.appendingPathComponent("\(leaf)/report.jpg"))
        try await addDocumentAndRecord(f, directory: "Vita Liber/\(leaf)", fileName: "report.jpg",
                                       conversationID: UUID())

        let changed = await f.mirror.migrateLegacyExportRootIfNeeded()
        #expect(changed)
        let row = await f.ledger.records(directoryName: "conversation/\(leaf)").first
        #expect(row?.relativePath == "conversation/\(leaf)/report.jpg")
    }

    @Test("新旧同在：跳过，不改账本也不覆盖")
    func keepsBothWhenConflict() async throws {
        let f = try await makeFixture()
        let leaf = "20261102-1435-会话-abcdef"
        try writeFile(f.exports.appendingPathComponent("Vita Liber/\(leaf)/report.jpg"))
        try writeFile(f.exports.appendingPathComponent("conversation/\(leaf)/other.jpg"))
        try await addDocumentAndRecord(f, directory: "Vita Liber/\(leaf)", fileName: "report.jpg",
                                       conversationID: UUID())

        let changed = await f.mirror.migrateLegacyExportRootIfNeeded()
        #expect(!changed)
        let row = await f.ledger.records(directoryName: "Vita Liber/\(leaf)").first
        #expect(row?.relativePath == "Vita Liber/\(leaf)/report.jpg")
        #expect(FileManager.default.fileExists(
            atPath: f.exports.appendingPathComponent("conversation/\(leaf)/other.jpg").path))
    }

    @Test("扁平会话目录补进 conversation/；直接导入月桶留在根")
    func movesFlatSessionButKeepsDirectImport() async throws {
        let f = try await makeFixture()
        let leaf = "20261102-1435-会话-abcdef"
        try writeFile(f.exports.appendingPathComponent("\(leaf)/report.jpg"))
        try await addDocumentAndRecord(f, directory: leaf, fileName: "report.jpg",
                                       conversationID: UUID())
        try writeFile(f.exports.appendingPathComponent("直接导入-2026-11/direct.jpg"))
        try await addDocumentAndRecord(f, directory: "直接导入-2026-11", fileName: "direct.jpg")

        let changed = await f.mirror.migrateLegacyExportRootIfNeeded()
        #expect(changed)
        #expect(FileManager.default.fileExists(
            atPath: f.exports.appendingPathComponent("conversation/\(leaf)/report.jpg").path))
        #expect(!FileManager.default.fileExists(
            atPath: f.exports.appendingPathComponent("\(leaf)/report.jpg").path))
        #expect(FileManager.default.fileExists(
            atPath: f.exports.appendingPathComponent("直接导入-2026-11/direct.jpg").path))
    }

    @Test("无账本行的孤儿目录也搬到 conversation/")
    func movesOrphanDirectory() async throws {
        let f = try await makeFixture()
        let leaf = "20261102-1435-孤儿-abcdef"
        try writeFile(f.exports.appendingPathComponent("Vita Liber/\(leaf)/orphan.jpg"))
        let changed = await f.mirror.migrateLegacyExportRootIfNeeded()
        #expect(changed)
        #expect(FileManager.default.fileExists(
            atPath: f.exports.appendingPathComponent("conversation/\(leaf)/orphan.jpg").path))
        #expect(!FileManager.default.fileExists(
            atPath: f.exports.appendingPathComponent("Vita Liber").path))
    }

    @Test("空旧根无账本行也清理")
    func removesEmptyLegacyRoot() async throws {
        let f = try await makeFixture()
        let legacy = f.exports.appendingPathComponent("Vita Liber", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let changed = await f.mirror.migrateLegacyExportRootIfNeeded()
        #expect(!changed)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }
}
#endif
