import Domain
import Foundation
import Testing
@testable import Infrastructure

/// 切片 journal 金样（B0 契约件；纯 Foundation，Linux 真跑）。
/// 行为镜像 v4 journal 的四分支收敛：clean / completed / restored / irrecoverable。
@Suite("SU-M2-SLICE · 激活 journal 四分支收敛")
struct CatalogSliceActivationJournalTests {

    /// 确定性 FNV 展开哈希（64 位小写十六进制；非密码学，仅桩）。
    private struct FakeHasher: Sendable {
        func sha256(_ url: URL) throws -> String {
            let data = try Data(contentsOf: url)
            var acc: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in data { acc = (acc ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            var out = ""
            for index in 0..<32 {
                acc = acc &* 0x0000_0100_0000_01b3 &+ UInt64(index)
                out += String(format: "%02x", UInt8(truncatingIfNeeded: acc >> 56))
            }
            return out
        }
    }

    private struct Fixture {
        let header = Data("SQLite format 3\u{0}".utf8)
        let directory: URL
        let hasher = FakeHasher()

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("slice-journal-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)   // try?-ok: 测试夹具
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }   // try?-ok: 测试清理

        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

        func write(_ name: String, _ body: String) throws {
            try (header + Data(body.utf8)).write(to: file(name))
        }

        func digest(_ name: String) throws -> String { try hasher.sha256(file(name)) }

        func journal(verify: (@Sendable (URL) throws -> Void)? = nil) -> CatalogSliceActivationJournal {
            CatalogSliceActivationJournal(
                journalURL: file("journal.json"), supportDirectory: directory,
                sha256: { try hasher.sha256($0) }, verifyInstalled: verify)
        }

        func pending(staging: String = "staging.sqlite",
                     active: String = "active.sqlite",
                     backup: String? = nil) throws -> CatalogSliceActivationJournal.Pending {
            CatalogSliceActivationJournal.Pending(
                kind: .drug, catalogVersion: 2, rootVersion: 1,
                sqliteSHA256: try digest(staging),
                signedPayloadDigest: String(repeating: "d", count: 64),
                stagingURL: file(staging), activeURL: file(active),
                lastGoodBackupURL: backup.map(file))
        }

        func replaceActiveFromStaging(_ pending: CatalogSliceActivationJournal.Pending) throws {
            try FileManager.default.removeItem(at: pending.activeURL)
            try FileManager.default.moveItem(at: pending.stagingURL, to: pending.activeURL)
        }
    }

    @Test("正常闭环：begin → 替换 → complete → recover = clean")
    func completeFlow() throws {
        let fixture = Fixture(); defer { fixture.cleanUp() }
        try fixture.write("active.sqlite", "old")
        try fixture.write("staging.sqlite", "new")
        let journal = fixture.journal()
        let pending = try fixture.pending()
        try journal.begin(pending)
        try fixture.replaceActiveFromStaging(pending)
        try journal.complete(pending)
        #expect(try journal.recoverBeforeOpen(catalogURL: pending.activeURL) == .clean)
        #expect(!FileManager.default.fileExists(atPath: fixture.file("journal.json").path))
    }

    @Test("替换未发生：recover = restoredLastGood，旧库原样")
    func crashBeforeReplace() throws {
        let fixture = Fixture(); defer { fixture.cleanUp() }
        try fixture.write("active.sqlite", "old")
        try fixture.write("staging.sqlite", "new")
        let journal = fixture.journal()
        let pending = try fixture.pending()
        try journal.begin(pending)
        #expect(try journal.recoverBeforeOpen(catalogURL: pending.activeURL) == .restoredLastGood)
        #expect(try String(contentsOf: pending.activeURL, encoding: .utf8) == "SQLite format 3\u{0}old")
        #expect(!FileManager.default.fileExists(atPath: pending.stagingURL.path))
    }

    @Test("替换已发生且复核通过：recover = completedActivation")
    func crashAfterReplace() throws {
        let fixture = Fixture(); defer { fixture.cleanUp() }
        try fixture.write("active.sqlite", "old")
        try fixture.write("staging.sqlite", "new")
        let journal = fixture.journal(verify: { _ in })
        let pending = try fixture.pending()
        try journal.begin(pending)
        try fixture.replaceActiveFromStaging(pending)
        #expect(try journal.recoverBeforeOpen(catalogURL: pending.activeURL) == .completedActivation)
        #expect(!FileManager.default.fileExists(atPath: fixture.file("journal.json").path))
        // 回执缺失时由 journal 重建（TD-SLICE-RECEIPT-01）。
        let rebuilt = CatalogSliceReceipt.read(kind: .drug, directory: fixture.directory)
        #expect(rebuilt?.catalogVersion == pending.catalogVersion)
        #expect(rebuilt?.sqliteSHA256 == pending.sqliteSHA256)
        #expect(rebuilt?.sqliteSize == (try CatalogPackageFiles.size(of: pending.activeURL)))
    }

    @Test("已有合法回执时恢复不覆盖")
    func recoveryKeepsExistingReceipt() throws {
        let fixture = Fixture(); defer { fixture.cleanUp() }
        try fixture.write("active.sqlite", "old")
        try fixture.write("staging.sqlite", "new")
        let existing = CatalogSliceReceipt(
            kind: .drug, catalogVersion: 1, rootVersion: 1,
            sqliteSHA256: String(repeating: "a", count: 64), sqliteSize: 1,
            signedPayloadDigest: String(repeating: "d", count: 64),
            installedAt: Date(timeIntervalSince1970: 1))
        #expect(CatalogSliceReceipt.write(existing, directory: fixture.directory))
        let journal = fixture.journal(verify: { _ in })
        let pending = try fixture.pending()
        try journal.begin(pending)
        try fixture.replaceActiveFromStaging(pending)
        #expect(try journal.recoverBeforeOpen(catalogURL: pending.activeURL) == .completedActivation)
        #expect(CatalogSliceReceipt.read(kind: .drug, directory: fixture.directory) == existing)
    }

    @Test("替换已发生但复核失败：last-good 兜底恢复旧库")
    func failedGateFallsBackToLastGood() throws {
        let fixture = Fixture(); defer { fixture.cleanUp() }
        try fixture.write("active.sqlite", "old")
        try fixture.write("staging.sqlite", "new")
        try fixture.write("backup.sqlite", "old")
        let journal = fixture.journal(verify: { _ in throw CatalogSliceActivationJournal.Failure.irrecoverable })
        let pending = try fixture.pending(backup: "backup.sqlite")
        try journal.begin(pending)
        try fixture.replaceActiveFromStaging(pending)
        #expect(try journal.recoverBeforeOpen(catalogURL: pending.activeURL) == .restoredLastGood)
        #expect(try String(contentsOf: pending.activeURL, encoding: .utf8) == "SQLite format 3\u{0}old")
    }

    @Test("路径逃逸拒写；损坏 journal 判 invalidState；双非可复核即 irrecoverable 且 active 被隔离")
    func failureBranches() throws {
        let fixture = Fixture(); defer { fixture.cleanUp() }
        try fixture.write("staging.sqlite", "new")
        let journal = fixture.journal()
        let escaping = CatalogSliceActivationJournal.Pending(
            kind: .drug, catalogVersion: 2, rootVersion: 1,
            sqliteSHA256: try fixture.digest("staging.sqlite"),
            signedPayloadDigest: String(repeating: "d", count: 64),
            stagingURL: URL(fileURLWithPath: "/tmp/escape-\(UUID().uuidString).sqlite"),
            activeURL: fixture.file("active.sqlite"))
        #expect(throws: CatalogSliceActivationJournal.Failure.pathEscape) {
            try journal.begin(escaping)
        }

        try Data("not json".utf8).write(to: fixture.file("journal.json"))
        #expect(throws: CatalogSliceActivationJournal.Failure.invalidState) {
            _ = try journal.recoverBeforeOpen(catalogURL: fixture.file("active.sqlite"))
        }
        try FileManager.default.removeItem(at: fixture.file("journal.json"))

        // irrecoverable：曾有旧库（begin 时 active 存在），恢复时 active 两端都不是
        try fixture.write("active.sqlite", "old")
        let pending = try fixture.pending()
        try journal.begin(pending)
        try Data("garbage".utf8).write(to: pending.activeURL)
        #expect(throws: CatalogSliceActivationJournal.Failure.irrecoverable) {
            _ = try journal.recoverBeforeOpen(catalogURL: pending.activeURL)
        }
        #expect(!FileManager.default.fileExists(atPath: pending.activeURL.path))
    }
}
