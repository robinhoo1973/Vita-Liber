import Foundation
import Testing
@testable import Domain
#if os(iOS) || os(macOS)
import GRDB
import ZIPFoundation
@testable import Infrastructure

/// 损坏数据库修复接口（业主 2026-10-30）文件级契约：打包 / 校验 / 替换 / 清除。
/// os 守卫：GRDB+ZIPFoundation 仅 Apple 平台链接（Linux 空单元）。
@Suite("数据库修复文件服务")
struct DatabaseRecoveryServiceTests {
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("db-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 造一个结构合法的患者库（全量 DDL + 指定 user_version）。
    private func makeDatabase(at path: String, version: Int = SchemaMigrations.latestVersion,
                              ddl: String = SchemaV2.ddl) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: ddl)
            try db.execute(sql: "PRAGMA user_version = \(version)")
        }
        try queue.close()
    }

    @Test("合法库通过校验并返回结构版本")
    func validatesGoodDatabase() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("good.sqlite").path
        try makeDatabase(at: path)
        let report = try DatabaseRecoveryService.validateRepairedDatabase(at: URL(fileURLWithPath: path))
        #expect(report.userVersion == SchemaMigrations.latestVersion)
    }

    @Test("非 SQLite 文件 / 头部有效但内容损坏 / 版本过新 / 缺必需表 —— 分类拒绝")
    func rejectsBadFiles() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理

        let text = dir.appendingPathComponent("text.sqlite")
        try Data("hello".utf8).write(to: text)
        #expect(throws: DatabaseRepairError.notSQLite) {
            try DatabaseRecoveryService.validateRepairedDatabase(at: text)
        }

        let truncated = dir.appendingPathComponent("truncated.sqlite")
        var bytes = Data("SQLite format 3\u{0}".utf8)
        bytes.append(Data(repeating: 0xAA, count: 256))
        try bytes.write(to: truncated)
        do {
            _ = try DatabaseRecoveryService.validateRepairedDatabase(at: truncated)
            Issue.record("损坏文件不得通过校验")
        } catch let error as DatabaseRepairError {
            switch error {
            case .unreadable, .integrityFailed: break
            default: Issue.record("意外错误分类: \(error)")
            }
        }

        let tooNew = dir.appendingPathComponent("too-new.sqlite").path
        try makeDatabase(at: tooNew, version: SchemaMigrations.latestVersion + 1)
        do {
            _ = try DatabaseRecoveryService.validateRepairedDatabase(at: URL(fileURLWithPath: tooNew))
            Issue.record("版本过新不得通过校验")
        } catch let error as DatabaseRepairError {
            #expect(error == .tooNew(found: SchemaMigrations.latestVersion + 1,
                                     supported: SchemaMigrations.latestVersion))
        }

        let missing = dir.appendingPathComponent("missing.sqlite").path
        try makeDatabase(at: missing, ddl: "CREATE TABLE patient_profile (id TEXT);")
        do {
            _ = try DatabaseRecoveryService.validateRepairedDatabase(at: URL(fileURLWithPath: missing))
            Issue.record("缺必需表不得通过校验")
        } catch let error as DatabaseRepairError {
            if case .missingTables(let tables) = error {
                #expect(tables.contains("document_file"))
            } else {
                Issue.record("意外错误分类: \(error)")
            }
        }
    }

    @Test("压缩包往返：单库可解出；多库/穿越路径拒绝")
    func archiveRoundTripAndGuards() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let db = dir.appendingPathComponent("app-local-user_data.sqlite").path
        try makeDatabase(at: db)
        let wal = dir.appendingPathComponent("app-local-user_data.sqlite-wal").path
        try Data([0x01, 0x02]).write(to: URL(fileURLWithPath: wal))

        let zip = dir.appendingPathComponent("repair.zip")
        try DatabaseRecoveryService.makeArchive(
            entries: [.init(name: "app-local-user_data.sqlite", path: db),
                      .init(name: "app-local-user_data.sqlite-wal", path: wal)],
            destination: zip)
        #expect(FileManager.default.fileExists(atPath: zip.path))

        let out = dir.appendingPathComponent("out", isDirectory: true)
        let extracted = try DatabaseRecoveryService.extractRepairedDatabase(from: zip, into: out)
        #expect(try Data(contentsOf: extracted) == Data(contentsOf: URL(fileURLWithPath: db)))
        // 解出的库仍应通过完整校验。
        _ = try DatabaseRecoveryService.validateRepairedDatabase(at: extracted)

        let second = dir.appendingPathComponent("second.sqlite").path
        try makeDatabase(at: second)
        let twoZip = dir.appendingPathComponent("two.zip")
        try DatabaseRecoveryService.makeArchive(
            entries: [.init(name: "a.sqlite", path: db), .init(name: "b.sqlite", path: second)],
            destination: twoZip)
        #expect(throws: DatabaseRepairError.self) {
            _ = try DatabaseRecoveryService.extractRepairedDatabase(
                from: twoZip, into: dir.appendingPathComponent("out2", isDirectory: true))
        }

        // 穿越路径：makeArchive 本身会拒绝；这里用原生 ZIPFoundation 造恶意包，
        // 验证解包侧同样拒绝（双端防线）。
        let evilZip = dir.appendingPathComponent("evil.zip")
        let evilArchive = try Archive(url: evilZip, accessMode: .create)
        try evilArchive.addEntry(with: "../evil.sqlite",
                                 fileURL: URL(fileURLWithPath: db))
        #expect(throws: DatabaseRepairError.self) {
            _ = try DatabaseRecoveryService.extractRepairedDatabase(
                from: evilZip, into: dir.appendingPathComponent("out3", isDirectory: true))
        }
    }

    @Test("替换：新库生效，旧库与 WAL 保留为 .corrupt-<ts> 副本")
    func installKeepsCorruptCopy() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let patient = dir.appendingPathComponent("app-local-user_data.sqlite").path
        let repaired = dir.appendingPathComponent("repaired.sqlite").path
        try Data("OLD-DB".utf8).write(to: URL(fileURLWithPath: patient))
        try Data("OLD-WAL".utf8).write(to: URL(fileURLWithPath: patient + "-wal"))
        try Data("NEW-DB".utf8).write(to: URL(fileURLWithPath: repaired))

        try DatabaseRecoveryService.install(repairedPath: repaired, patientPath: patient,
                                            now: Date(timeIntervalSince1970: 1000))
        #expect(try Data(contentsOf: URL(fileURLWithPath: patient)) == Data("NEW-DB".utf8))
        #expect(!FileManager.default.fileExists(atPath: patient + "-wal"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: patient + ".corrupt-1000"))
                == Data("OLD-DB".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: patient + ".corrupt-1000-wal"))
                == Data("OLD-WAL".utf8))
    }

    @Test("清除：规范名/历史名/伴生/损坏副本全删，无关目录文件保留")
    func eraseRemovesAllPatientCopies() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let patient = dir.appendingPathComponent(PatientDatabaseNames.canonical).path
        try Data("x".utf8).write(to: URL(fileURLWithPath: patient))
        try Data("x".utf8).write(to: URL(fileURLWithPath: patient + "-wal"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: patient + ".corrupt-999"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: patient + ".corrupt-999-wal"))
        try Data("x".utf8).write(to: URL(fileURLWithPath:
            dir.appendingPathComponent(PatientDatabaseNames.legacy).path))
        let unrelated = dir.appendingPathComponent("medical-catalog.sqlite").path
        try Data("keep".utf8).write(to: URL(fileURLWithPath: unrelated))

        try DatabaseRecoveryService.erasePatientDatabase(patientPath: patient)
        #expect(!FileManager.default.fileExists(atPath: patient))
        #expect(!FileManager.default.fileExists(atPath: patient + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: patient + ".corrupt-999"))
        #expect(!FileManager.default.fileExists(atPath: patient + ".corrupt-999-wal"))
        #expect(!FileManager.default.fileExists(atPath:
            dir.appendingPathComponent(PatientDatabaseNames.legacy).path))
        #expect(FileManager.default.fileExists(atPath: unrelated))
    }
}
#endif
