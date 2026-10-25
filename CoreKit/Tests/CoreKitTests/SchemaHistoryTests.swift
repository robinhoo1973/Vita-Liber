#if os(iOS) || os(macOS)
import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

@Suite("SU-M0-DBBOOT · 历史库与升级服务")
struct SchemaHistoryTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func seedDecodesToVersionedSQL() throws {
        let sql = try SchemaHistorySeed.sql()
        #expect(sql.contains("CREATE TABLE schema_step"))
        #expect(sql.contains("VALUES(48,'health-problem-department'"))
        #expect(sql.contains("CREATE TABLE migration_attempt"))
    }

    @Test func seedMirrorsMigrations() throws {
        let sql = try SchemaHistorySeed.sql()
        #expect(sql.contains("(1,'baseline','sql'"))
        for step in SchemaMigrations.steps {
            let kind = step.sql.isEmpty ? "code" : "sql"
            #expect(sql.contains("(\(step.version),'\(step.name)','\(kind)'"),
                    "seed 缺少 v\(step.version) \(step.name)")
        }
        #expect(sql.contains("VALUES(\(SchemaMigrations.latestVersion),'"))
    }

    @Test func rebuildClearsPreviousContents() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("app-local-schema-history.sqlite").path
        let first = try SchemaHistoryStore.rebuild(at: path)
        try first.recordAttempt(.init(databaseName: "app-local-user_data.sqlite",
                                      sourceVersion: 47, targetVersion: 48,
                                      outcome: "success", detail: nil))
        #expect(try first.contents().attempts.count == 1)

        let second = try SchemaHistoryStore.rebuild(at: path)
        let contents = try second.contents()
        #expect(contents.attempts.isEmpty)
        #expect(contents.steps.count == SchemaMigrations.steps.count + 1)
        #expect(contents.steps.last?.version == SchemaMigrations.latestVersion)
        #expect(contents.registry.count == 3)
        #expect(contents.meta["history_schema_version"] == "1")
    }

    @Test func observationRoundTrip() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("history.sqlite").path
        let store = try SchemaHistoryStore.rebuild(at: path)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.record(.init(name: "app-local-user_data.sqlite", role: "user-data",
                               exists: true, sizeBytes: 4096, headerValid: true,
                               observedVersion: 48, requiredTables: 3, observedAt: date))
        let rows = try store.contents().observations
        #expect(rows.count == 1)
        #expect(rows[0].observedVersion == 48)
        #expect(rows[0].requiredTables == 3)
        #expect(abs(rows[0].observedAt.timeIntervalSince(date)) < 0.001)
    }

    @Test func probeMissingFileDoesNotCreateIt() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("missing.sqlite").path
        let probe = DatabaseProbe.inspect(path: path,
                                          requiredTables: DatabaseBootPolicy.requiredTables,
                                          originalsPresent: false)
        #expect(probe.exists == false)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(DatabaseBootPolicy.decide(probe, supportedVersion: 48) == .fresh)
    }

    @Test func probeReadsBaselineAndPolicySaysReady() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("app-local-user_data.sqlite").path
        _ = try GRDBStore.pool(at: path)
        let probe = DatabaseProbe.inspect(path: path,
                                          requiredTables: DatabaseBootPolicy.requiredTables,
                                          originalsPresent: false)
        #expect(probe.exists)
        #expect(probe.headerValid)
        #expect(probe.observedVersion == SchemaMigrations.latestVersion)
        #expect(probe.hasAllRequiredTables)
        #expect(DatabaseBootPolicy.decide(probe, supportedVersion: SchemaMigrations.latestVersion)
                == .ready(version: SchemaMigrations.latestVersion))
    }

    @Test func zeroByteFileIsCorrupt() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("empty.sqlite").path
        try Data().write(to: URL(fileURLWithPath: path))
        let probe = DatabaseProbe.inspect(path: path,
                                          requiredTables: DatabaseBootPolicy.requiredTables,
                                          originalsPresent: false)
        #expect(probe.exists)
        #expect(probe.sizeBytes == 0)
        #expect(DatabaseBootPolicy.decide(probe, supportedVersion: 48) == .corrupt(.emptyFile))
    }
    @Test func upgradeServiceValidatesSourceAndTarget() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("user.sqlite").path
        _ = try DatabaseUpgradeService.open(
            at: path, from: nil, to: SchemaMigrations.latestVersion,
            requiredTables: DatabaseBootPolicy.requiredTables)
        _ = try DatabaseUpgradeService.open(
            at: path, from: SchemaMigrations.latestVersion,
            to: SchemaMigrations.latestVersion,
            requiredTables: DatabaseBootPolicy.requiredTables)
        #expect(throws: DatabaseUpgradeError.sourceMismatch(
            expected: 1, found: SchemaMigrations.latestVersion)) {
            try DatabaseUpgradeService.open(
                at: path, from: 1, to: SchemaMigrations.latestVersion,
                requiredTables: DatabaseBootPolicy.requiredTables)
        }
    }

}
#endif
