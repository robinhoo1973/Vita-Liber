#if os(iOS) || os(macOS)
import Foundation
import GRDB
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
        #expect(sql.contains("VALUES(49,'document-user-export'"))
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

    @Test func seedStepSQLMatchesMigrations() throws {
        // 版本序列一致还不够：SQL 体漂移会让历史投影失真（2026-10-27 审查 P3）。
        let sql = try SchemaHistorySeed.sql()
        let queue = try DatabaseQueue()
        try queue.write { db in try db.execute(sql: sql) }
        let seeded = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT version, sql FROM schema_step ORDER BY version")
        }
        var expected: [(Int, String)] = [(SchemaMigrations.baselineVersion, MigrationEngine.schemaV1)]
        expected += SchemaMigrations.steps.map { ($0.version, $0.sql) }
        #expect(seeded.count == expected.count)
        for (row, pair) in zip(seeded, expected) {
            #expect((row["version"] as Int) == pair.0)
            #expect((row["sql"] as String) == pair.1, "v\(pair.0) seed SQL 与 SchemaMigrations 不一致")
        }
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
        #expect(contents.registry.count == 6)
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
    // 2026-10-28 切片-only B2：`CatalogSchemaProbe`（v4 catalog_meta 探测）随 v4 链删除，
    // 对应探测断言一并退役；切片启动探测由 `CatalogSliceProbe`（表集/slice_meta/COUNT）承担。

    private func makeCatalog(_ url: URL, schema: String?) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE catalog_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            if let schema {
                try db.execute(
                    sql: "INSERT INTO catalog_meta(key, value) VALUES('app_catalog_schema_version', ?)",
                    arguments: [schema])
            }
            try db.execute(sql: "PRAGMA user_version = 7")
        }
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
