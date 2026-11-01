#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Testing
@testable import Domain
@testable import Infrastructure

// binds: SU-M0-DBBOOT-SAFETY（2026-11-01 迁移安全网；三席两轮裁决 B1）
@Suite("SU-M0-DBBOOT-SAFETY · 迁移前快照")
struct MigrationCheckpointTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 最小可校验患者库：三个必需表 + 指定 user_version。
    private func makeDatabase(at path: String, version: Int) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE patient_profile(id TEXT);
                CREATE TABLE app_settings(id TEXT);
                CREATE TABLE document_file(id TEXT);
                """)
            try db.execute(sql: "PRAGMA user_version = \(version)")
        }
        try queue.close()
    }

    @Test func prepareCopiesSourceVersionAndReuses() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let databasePath = dir.appendingPathComponent("app-local-user_data.sqlite").path
        try makeDatabase(at: databasePath, version: 48)

        let checkpoint = try MigrationCheckpointStore.prepare(
            databasePath: databasePath, from: 48, to: 50)
        #expect(checkpoint.sourceVersion == 48)
        #expect(checkpoint.targetVersion == 50)
        #expect(checkpoint.sizeBytes > 0)
        #expect(FileManager.default.fileExists(atPath: checkpoint.path))
        let probe = DatabaseProbe.inspect(
            path: checkpoint.path, requiredTables: [], originalsPresent: false)
        #expect(probe.observedVersion == 48)

        let reused = try MigrationCheckpointStore.prepare(
            databasePath: databasePath, from: 48, to: 50)
        #expect(reused.path == checkpoint.path)
    }

    @Test func restoreReplacesCurrentDatabaseAndArchivesIt() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let databasePath = dir.appendingPathComponent("app-local-user_data.sqlite").path
        try makeDatabase(at: databasePath, version: 48)
        let checkpoint = try MigrationCheckpointStore.prepare(
            databasePath: databasePath, from: 48, to: 50)

        // 模拟半升级后的当前库（版本已推进）。
        try makeDatabase(at: databasePath, version: 50)
        try MigrationCheckpointStore.restore(checkpoint, patientPath: databasePath)

        let probe = DatabaseProbe.inspect(
            path: databasePath, requiredTables: DatabaseBootPolicy.requiredTables,
            originalsPresent: false)
        #expect(probe.observedVersion == 48)
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(entries.contains { $0.contains(".corrupt-") })
    }

    @Test func discardAllRemovesCheckpoint() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let databasePath = dir.appendingPathComponent("app-local-user_data.sqlite").path
        try makeDatabase(at: databasePath, version: 48)
        let checkpoint = try MigrationCheckpointStore.prepare(
            databasePath: databasePath, from: 48, to: 50)
        MigrationCheckpointStore.discardAll(databasePath: databasePath)
        #expect(!FileManager.default.fileExists(atPath: checkpoint.path))
    }
}
#endif
