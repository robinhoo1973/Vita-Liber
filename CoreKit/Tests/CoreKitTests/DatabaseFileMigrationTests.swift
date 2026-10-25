#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Testing
@testable import Infrastructure

struct DatabaseFileMigrationTests {
    @Test func migratesSealedWALDatabaseAndRemovesLegacyPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("db-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // try?-ok: test cleanup

        let old = root.appendingPathComponent("vitaliber.sqlite")
        let new = root.appendingPathComponent("app-local-user_data.sqlite")
        do {
            // WAL 必须在开库时配置：GRDB 的 write{} 自带事务，事务内
            // PRAGMA journal_mode=WAL 会被 SQLite 拒绝
            //（cannot change into wal mode from within a transaction）。
            var configuration = Configuration()
            configuration.journalMode = .wal
            let queue = try DatabaseQueue(path: old.path, configuration: configuration)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE sample(id INTEGER PRIMARY KEY, value TEXT)")
                try db.execute(sql: "INSERT INTO sample(value) VALUES ('kept')")
            }
            let journalMode = try queue.read { db in
                try String.fetchOne(db, sql: "PRAGMA journal_mode")
            }
            #expect(journalMode?.lowercased() == "wal")
        }

        try DatabaseFileMigration.migrate(from: old, to: new)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.path))
        let queue = try DatabaseQueue(path: new.path)
        let value = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM sample WHERE id=1")
        }
        #expect(value == "kept")
    }

    @Test func refusesToOverwriteExistingTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("db-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // try?-ok: test cleanup
        let old = root.appendingPathComponent("vitaliber.sqlite")
        let new = root.appendingPathComponent("app-local-user_data.sqlite")
        try Data("old".utf8).write(to: old)
        try Data("new".utf8).write(to: new)
        #expect(throws: DatabaseFileMigration.Failure.self) {
            try DatabaseFileMigration.migrate(from: old, to: new)
        }
        #expect(try Data(contentsOf: old) == Data("old".utf8))
        #expect(try Data(contentsOf: new) == Data("new".utf8))
    }

    @Test func refusesNonSQLiteSourceAndKeepsItInPlace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("db-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // try?-ok: test cleanup
        let old = root.appendingPathComponent("vitaliber.sqlite")
        let new = root.appendingPathComponent("app-local-user_data.sqlite")
        try Data("not a database".utf8).write(to: old)

        #expect(throws: DatabaseFileMigration.Failure.self) {
            try DatabaseFileMigration.migrate(from: old, to: new)
        }
        // 无法封库的源文件绝不能被移动/删除，否则旧库只剩一个不可读的目标文件。
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }
}
#endif
