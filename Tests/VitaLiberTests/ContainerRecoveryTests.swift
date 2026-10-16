import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber
@testable import CoreKit

/// 库丢失判据（双布局）与媒体生命周期（local-storage-layout-council §8 切片 13，macOS CI）。
@MainActor
final class ContainerRecoveryTests: XCTestCase {

    private let sha = String(repeating: "ab", count: 32)

    private func tempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, _ bytes: [UInt8]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    // MARK: databaseWasLost 双布局判据（6 案 + 边界）

    func test_databasePresentNeverLost() throws {
        let dir = try tempDir("lost-present")
        let dbPath = dir.appendingPathComponent("vitaliber.sqlite").path
        try Data([1]).write(to: URL(fileURLWithPath: dbPath))
        // 无论目录里有什么，库在 → 不判丢失
        try write(dir.appendingPathComponent("originals/ab/\(sha).bin"), [1])
        XCTAssertFalse(AppContainer.databaseWasLost(databasePath: dbPath, originalsDir: dir))
    }

    func test_databaseMissingWithEmptyDirsNotLost() throws {
        let dir = try tempDir("lost-empty")
        // 目录常驻创建（启动 mkdir）不是「曾写数据」的证据
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("originals/ab"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sensitive/\(UUID().uuidString)"), withIntermediateDirectories: true)
        XCTAssertFalse(AppContainer.databaseWasLost(databasePath: dir.appendingPathComponent("missing.sqlite").path,
                                                    originalsDir: dir))
    }

    func test_databaseMissingWithCASFileIsLost() throws {
        let dir = try tempDir("lost-cas")
        try write(dir.appendingPathComponent("originals/ab/\(sha).bin"), [1, 2])
        XCTAssertTrue(AppContainer.databaseWasLost(databasePath: dir.appendingPathComponent("missing.sqlite").path,
                                                   originalsDir: dir))
    }

    func test_databaseMissingWithSensitiveFileIsLost() throws {
        let dir = try tempDir("lost-sensitive")
        try write(dir.appendingPathComponent("sensitive/\(UUID().uuidString)/\(sha).bin"), [1])
        XCTAssertTrue(AppContainer.databaseWasLost(databasePath: dir.appendingPathComponent("missing.sqlite").path,
                                                   originalsDir: dir))
    }

    func test_databaseMissingWithLegacyLayoutFileIsLost() throws {
        let dir = try tempDir("lost-legacy")
        try write(dir.appendingPathComponent("originals/\(UUID().uuidString)/\(UUID().uuidString).jpg"), [1])
        XCTAssertTrue(AppContainer.databaseWasLost(databasePath: dir.appendingPathComponent("missing.sqlite").path,
                                                   originalsDir: dir))
    }

    func test_databaseMissingWithOnlyHiddenFilesNotLost() throws {
        let dir = try tempDir("lost-hidden")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("originals"), withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("originals/.DS_Store"))
        XCTAssertFalse(AppContainer.databaseWasLost(databasePath: dir.appendingPathComponent("missing.sqlite").path,
                                                    originalsDir: dir))
    }

    func test_databaseMissingWithRootStrayFileIsLost() throws {
        let dir = try tempDir("lost-root")
        try write(dir.appendingPathComponent("stray.bin"), [1])
        XCTAssertTrue(AppContainer.databaseWasLost(databasePath: dir.appendingPathComponent("missing.sqlite").path,
                                                   originalsDir: dir))
    }

    // MARK: MediaReconciler：懒回填 / 对账 / 清空 / 成员删除

    private func makeStoreWithDocument(mediaBase: URL) async throws -> (store: GRDBStore, patient: UUID, docId: UUID) {
        let store = try GRDBStore.inMemory()
        let patient = UUID()
        let docId = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, 'Owner', 'self', 10, 20)
                """, arguments: [patient.uuidString])
            // 列 NULL（legacy 行）：懒回填目标
            try db.execute(sql: """
                INSERT INTO document_file (id, patient_id, doc_type, status, sha256, mime_type,
                                           is_sensitive, origin, meta_json, created_at, updated_at)
                VALUES (?, ?, '检验报告', 'active', 'file:legacy', 'image/png', 0, 'camera', ?, 10, 20)
                """, arguments: [docId.uuidString, patient.uuidString, "{\"original_path\":\"/tmp/legacy.png\"}"])
        }
        return (store, patient, docId)
    }

    func test_backfillOriginalSHAWritesColumnOnly() async throws {
        let mediaBase = try tempDir("reconciler-backfill")
        let legacyFile = mediaBase.appendingPathComponent("legacy.png")
        try Data([7, 7, 7]).write(to: legacyFile)
        let (store, _, docId) = try await makeStoreWithDocument(mediaBase: mediaBase)
        // 回填经 resolver：meta 绝对路径 → 找到文件 → 哈希写列（不动文件）
        let meta = try JSONSerialization.data(withJSONObject: ["original_path": legacyFile.path])
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE document_file SET meta_json = ? WHERE id = ?",
                           arguments: [String(decoding: meta, as: UTF8.self), docId.uuidString])
        }
        let reconciler = MediaReconciler(mediaBase: mediaBase, writer: store.writer)
        let updated = try await reconciler.backfillOriginalSHA()
        XCTAssertEqual(updated, 1)
        let row = try await store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT original_sha256 FROM document_file WHERE id = ?",
                             arguments: [docId.uuidString])
        }
        XCTAssertEqual(row?["original_sha256"] as String?, CryptoKitContentHasher().sha256Hex(Data([7, 7, 7])))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))   // 只写列不动文件
    }

    func test_reconcileKeepsReferencedAndLegacyDeletesOnlyUnreferenced() async throws {
        let mediaBase = try tempDir("reconciler-gc")
        // ①引用在库 → keep；②无引用超宽限 → 删；③旧布局 → keep；④.partial 未超宽限 → keep
        try write(mediaBase.appendingPathComponent("originals/ab/\(sha).bin"), [1])
        try write(mediaBase.appendingPathComponent("originals/cd/\(String(repeating: "c", count: 32) + String(repeating: "d", count: 32)).bin"), [2])
        try write(mediaBase.appendingPathComponent("originals/\(UUID().uuidString)/\(UUID().uuidString).jpg"), [3])
        let partialURL = mediaBase.appendingPathComponent("originals/ef/\(String(repeating: "e", count: 32) + String(repeating: "f", count: 32)).bin.partial")
        try write(partialURL, [4])
        let (store, patient, _) = try await makeStoreWithDocument(mediaBase: mediaBase)
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO document_file (id, patient_id, doc_type, status, sha256, mime_type,
                                           is_sensitive, origin, meta_json, created_at, updated_at, original_sha256)
                VALUES (?, ?, '检验报告', 'active', 'sha:x', 'image/png', 0, 'camera', '{}', 10, 20, ?)
                """, arguments: [UUID().uuidString, patient.uuidString, sha])
        }
        let reconciler = MediaReconciler(mediaBase: mediaBase, writer: store.writer)
        // 把参与判定的文件 mtime 拨到远古（超宽限），靠引用集分胜负；partial 保持新建（宽限内）
        let legacyName = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            atPath: mediaBase.appendingPathComponent("originals").path).first { $0.count == 36 })
        let legacyFile = mediaBase.appendingPathComponent("originals/\(legacyName)")
            .appendingPathComponent(try XCTUnwrap(FileManager.default.contentsOfDirectory(
                atPath: mediaBase.appendingPathComponent("originals/\(legacyName)").path).first))
        for file in [mediaBase.appendingPathComponent("originals/ab/\(sha).bin"),
                     mediaBase.appendingPathComponent("originals/cd/\(String(repeating: "c", count: 32) + String(repeating: "d", count: 32)).bin"),
                     legacyFile] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                                  ofItemAtPath: file.path)
        }
        let report = try await reconciler.reconcile()
        // 引用文件保留
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaBase.appendingPathComponent("originals/ab/\(sha).bin").path))
        // 无引用 → 删
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaBase.appendingPathComponent("originals/cd/\(String(repeating: "c", count: 32) + String(repeating: "d", count: 32)).bin").path))
        // 旧布局 keep
        XCTAssertTrue(FileManager.default.contentsOfDirectory(atPath: mediaBase.appendingPathComponent("originals").path).contains { $0.count == 36 })
        // 宽限内 partial keep（新建文件）
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialURL.path))
        XCTAssertEqual(report.deletedOriginals, 1)
    }

    func test_wipeAllMediaAndWipeMember() async throws {
        let mediaBase = try tempDir("reconciler-wipe")
        try write(mediaBase.appendingPathComponent("originals/ab/\(sha).bin"), [1])
        let member = UUID()
        try write(mediaBase.appendingPathComponent("sensitive/\(member.uuidString)/\(sha).bin"), [2])
        let store = try GRDBStore.inMemory()
        let reconciler = MediaReconciler(mediaBase: mediaBase, writer: store.writer)
        await reconciler.wipeMember(member)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaBase.appendingPathComponent("sensitive").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaBase.appendingPathComponent("originals/ab/\(sha).bin").path))
        await reconciler.wipeAllMedia()
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaBase.appendingPathComponent("originals").path))
    }
}
