import Foundation
import Testing
@testable import Infrastructure

/// 平台中立（Linux 可跑）：`MedicalCatalogActivationJournal` 的 begin/complete 语义
/// 与崩溃恢复矩阵。SHA-256 经 `ReferenceSHA256`（MedicalCatalogUpdateTests.swift 定义，
/// 同测试目标内共享）注入，不依赖 CryptoKit；Apple-only 的 schema/meta 复核门
/// （真实实现见 `MedicalCatalogActivationJournal+Apple.swift`，仅 macOS CI 跑得到 GRDB）
/// 在此用可控的替身闭包演练同一条件分支。
@Suite("Medical catalog activation journal")
struct MedicalCatalogActivationJournalTests {

    // MARK: begin/complete

    @Test("begin persists a recoverable record; complete removes journal and backup")
    func beginThenCompleteRoundTrips() throws {
        let fixture = try JournalFixture.make(hadActive: true)
        defer { fixture.cleanUp() }
        let journal = fixture.journal()
        let pending = fixture.pending()

        try journal.begin(pending)
        #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))

        try journal.complete(pending)
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.backupURL.path))
    }

    @Test("begin rejects paths outside the catalog support directory")
    func beginRejectsPathEscape() throws {
        let fixture = try JournalFixture.make(hadActive: true)
        defer { fixture.cleanUp() }
        let journal = fixture.journal()
        let outside = fixture.directory.deletingLastPathComponent().appendingPathComponent("outside.sqlite")
        try fixture.newBytes.write(to: outside)
        let escaping = PendingActivation(candidate: fixture.candidate, stagingURL: outside,
                                         activeURL: fixture.activeURL, lastGoodBackupURL: nil)
        #expect(throws: MedicalCatalogActivationJournal.Failure.pathEscape) {
            try journal.begin(escaping)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    // MARK: crash matrix — recoverBeforeOpen must always land on old-readable or new-validated

    @Test("crash before journal.begin(): no journal on disk yet, recovery is a no-op (clean)")
    func crashBeforeJournalBegins() throws {
        let fixture = try JournalFixture.make(hadActive: true)
        defer { fixture.cleanUp() }
        let old = try fixture.oldBytesRequired()
        // staging + backup already created by the (crashed) installer, journal never written.
        try fixture.newBytes.write(to: fixture.stagingURL)
        try old.write(to: fixture.backupURL)

        let outcome = try fixture.journal().recoverBeforeOpen(catalogURL: fixture.activeURL)
        #expect(outcome == .clean)
        #expect(fixture.hash(fixture.activeURL) == fixture.hash(old))
        #expect(fixture.patientUnchanged())
    }

    @Test("crash after staging on a first-ever install (no prior active, no backup): clean")
    func crashAfterStagingFirstInstall() throws {
        let fixture = try JournalFixture.make(hadActive: false)
        defer { fixture.cleanUp() }
        try fixture.newBytes.write(to: fixture.stagingURL)
        // no backup (there was nothing to back up), no journal, active does not exist.

        let outcome = try fixture.journal().recoverBeforeOpen(catalogURL: fixture.activeURL)
        #expect(outcome == .clean)
        #expect(!FileManager.default.fileExists(atPath: fixture.activeURL.path))
        #expect(fixture.patientUnchanged())
    }

    @Test("crash after journal.begin(), before the active swap: active is still the old catalog")
    func crashAfterJournalBeginsBeforeSwap() throws {
        let fixture = try JournalFixture.make(hadActive: true)
        defer { fixture.cleanUp() }
        let old = try fixture.oldBytesRequired()
        try fixture.newBytes.write(to: fixture.stagingURL)
        try old.write(to: fixture.backupURL)
        try fixture.journal().begin(fixture.pending())
        // atomicRename(staging -> active) never happened: active untouched.

        let outcome = try fixture.journal().recoverBeforeOpen(catalogURL: fixture.activeURL)
        #expect(outcome == .restoredLastGood)
        #expect(fixture.hash(fixture.activeURL) == fixture.hash(old))
        #expect(!FileManager.default.fileExists(atPath: fixture.stagingURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.backupURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
        #expect(fixture.patientUnchanged())
    }

    @Test("crash after reopen failed and the in-process rollback already restored the backup")
    func crashAfterInProcessRollbackRenamedBackupBack() throws {
        let fixture = try JournalFixture.make(hadActive: true)
        defer { fixture.cleanUp() }
        let old = try fixture.oldBytesRequired()
        try fixture.newBytes.write(to: fixture.stagingURL)
        try old.write(to: fixture.backupURL)
        try fixture.journal().begin(fixture.pending())
        // Simulate the same sequence MedicalCatalogUpdateService+Install.swift runs in-process:
        // atomicRename(staging -> active), activeCheck fails, restoreLastGood(backup) renames
        // backup back over active. journal.complete() is never reached (matches Task 4's
        // "journal stays at begin" comment) — but the backup file itself is now consumed.
        #expect(rename(fixture.stagingURL.path, fixture.activeURL.path) == 0)
        #expect(rename(fixture.backupURL.path, fixture.activeURL.path) == 0)

        let outcome = try fixture.journal().recoverBeforeOpen(catalogURL: fixture.activeURL)
        #expect(outcome == .restoredLastGood)
        #expect(fixture.hash(fixture.activeURL) == fixture.hash(old))
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
        #expect(fixture.patientUnchanged())
    }

    @Test("crash after the active swap, before reopen ran: recovery independently validates the new catalog")
    func crashAfterActiveSwapBeforeReopen() throws {
        let fixture = try JournalFixture.make(hadActive: true)
        defer { fixture.cleanUp() }
        try fixture.oldBytesRequired().write(to: fixture.backupURL)
        try fixture.newBytes.write(to: fixture.stagingURL)
        try fixture.journal().begin(fixture.pending())
        #expect(rename(fixture.stagingURL.path, fixture.activeURL.path) == 0)
        // No one has reopened `active` yet — recovery must do its own SHA + gate check.

        let outcome = try fixture.journal(verifyInstalled: { _, _, _ in }).recoverBeforeOpen(catalogURL: fixture.activeURL)
        #expect(outcome == .completedActivation)
        #expect(fixture.hash(fixture.activeURL) == fixture.hash(fixture.newBytes))
        #expect(!FileManager.default.fileExists(atPath: fixture.backupURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
        #expect(fixture.patientUnchanged())
    }

    @Test("reopen would have failed (schema/meta gate rejects): recovery restores last-good, never trusts the SHA match alone")
    func reopenGateFailureRestoresLastGood() throws {
        let fixture = try JournalFixture.make(hadActive: true)
        defer { fixture.cleanUp() }
        let old = try fixture.oldBytesRequired()
        try old.write(to: fixture.backupURL)
        try fixture.newBytes.write(to: fixture.stagingURL)
        try fixture.journal().begin(fixture.pending())
        #expect(rename(fixture.stagingURL.path, fixture.activeURL.path) == 0)

        struct GateFailure: Error {}
        let outcome = try fixture.journal(verifyInstalled: { _, _, _ in throw GateFailure() })
            .recoverBeforeOpen(catalogURL: fixture.activeURL)
        #expect(outcome == .restoredLastGood)
        #expect(fixture.hash(fixture.activeURL) == fixture.hash(old))
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
        #expect(fixture.patientUnchanged())
    }

    @Test("crash after active-state commit and before cleanup: leftover backup with no journal is ignored (clean)")
    func crashAfterCompleteRemovedJournalBeforeRemovingBackup() throws {
        let fixture = try JournalFixture.make(hadActive: true)
        defer { fixture.cleanUp() }
        try fixture.oldBytesRequired().write(to: fixture.backupURL)
        try fixture.newBytes.write(to: fixture.stagingURL)
        try fixture.journal().begin(fixture.pending())
        #expect(rename(fixture.stagingURL.path, fixture.activeURL.path) == 0)
        // journal.complete() removed the journal file but crashed before removing the backup.
        try FileManager.default.removeItem(at: fixture.journalURL)

        let outcome = try fixture.journal().recoverBeforeOpen(catalogURL: fixture.activeURL)
        #expect(outcome == .clean)
        #expect(fixture.hash(fixture.activeURL) == fixture.hash(fixture.newBytes))
        // Orphaned backup with no journal is out of scope for recovery — harmless leftover.
        #expect(FileManager.default.fileExists(atPath: fixture.backupURL.path))
        #expect(fixture.patientUnchanged())
    }

    @Test("active neither matches old nor new, and there is no prior catalog to fall back to: corrupt file is dropped")
    func corruptActiveWithNoPriorFallsBackToUninstalled() throws {
        let fixture = try JournalFixture.make(hadActive: false)
        defer { fixture.cleanUp() }
        try fixture.newBytes.write(to: fixture.stagingURL)
        try fixture.journal().begin(fixture.pending())
        #expect(rename(fixture.stagingURL.path, fixture.activeURL.path) == 0)
        // Corrupt the just-activated file after the rename (disk corruption, not our own writes).
        try Data("garbage".utf8).write(to: fixture.activeURL)

        let outcome = try fixture.journal().recoverBeforeOpen(catalogURL: fixture.activeURL)
        #expect(outcome == .restoredLastGood)
        #expect(!FileManager.default.fileExists(atPath: fixture.activeURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
        #expect(fixture.patientUnchanged())
    }

    @Test("active neither matches old nor new but a valid backup exists: it is used to restore last-good")
    func corruptActiveWithValidBackupRestores() throws {
        let fixture = try JournalFixture.make(hadActive: true)
        defer { fixture.cleanUp() }
        let old = try fixture.oldBytesRequired()
        try old.write(to: fixture.backupURL)
        try fixture.newBytes.write(to: fixture.stagingURL)
        try fixture.journal().begin(fixture.pending())
        #expect(rename(fixture.stagingURL.path, fixture.activeURL.path) == 0)
        try Data("garbage".utf8).write(to: fixture.activeURL)

        let outcome = try fixture.journal().recoverBeforeOpen(catalogURL: fixture.activeURL)
        #expect(outcome == .restoredLastGood)
        #expect(fixture.hash(fixture.activeURL) == fixture.hash(old))
        #expect(fixture.patientUnchanged())
    }

    @Test("active and backup both unusable and a prior catalog was recorded: recovery fails closed rather than guessing, and quarantines the unverified file")
    func irrecoverableWhenNeitherActiveNorBackupVerify() throws {
        let fixture = try JournalFixture.make(hadActive: true)
        defer { fixture.cleanUp() }
        try fixture.newBytes.write(to: fixture.stagingURL)
        try fixture.journal().begin(fixture.pending())
        #expect(rename(fixture.stagingURL.path, fixture.activeURL.path) == 0)
        try Data("garbage".utf8).write(to: fixture.activeURL)
        // No backup was ever created despite the journal recording a prior active hash.

        #expect(throws: MedicalCatalogActivationJournal.Failure.irrecoverable) {
            try fixture.journal().recoverBeforeOpen(catalogURL: fixture.activeURL)
        }
        // The unverified bytes must never be left readable at the active path — nothing
        // (in particular MedicalCatalogStore, which does no hash/schema validation on init)
        // must ever be able to open them there.
        #expect(!FileManager.default.fileExists(atPath: fixture.activeURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
            .filter { $0.hasPrefix(fixture.activeURL.lastPathComponent + ".quarantine-") }
        #expect(quarantined.count == 1)
        #expect(fixture.patientUnchanged())
    }

    @Test("no journal at all: recovery is a pure no-op regardless of what is at the active path")
    func noJournalIsClean() throws {
        let fixture = try JournalFixture.make(hadActive: true)
        defer { fixture.cleanUp() }
        let old = try fixture.oldBytesRequired()
        let outcome = try fixture.journal().recoverBeforeOpen(catalogURL: fixture.activeURL)
        #expect(outcome == .clean)
        #expect(fixture.hash(fixture.activeURL) == fixture.hash(old))
        #expect(fixture.patientUnchanged())
    }

    // MARK: bounded, versioned journal

    @Test("a journal file that fails to decode is treated as invalid state, not as clean")
    func undecodableJournalIsInvalidState() throws {
        let fixture = try JournalFixture.make(hadActive: true)
        defer { fixture.cleanUp() }
        let old = try fixture.oldBytesRequired()
        try Data("not a journal".utf8).write(to: fixture.journalURL)
        #expect(throws: MedicalCatalogActivationJournal.Failure.invalidState) {
            try fixture.journal().recoverBeforeOpen(catalogURL: fixture.activeURL)
        }
        #expect(fixture.hash(fixture.activeURL) == fixture.hash(old))
        #expect(fixture.patientUnchanged())
    }

    @Test("recoverBeforeOpen rejects a journal recorded for a different active path")
    func recoveryRejectsMismatchedActivePath() throws {
        let fixture = try JournalFixture.make(hadActive: true)
        defer { fixture.cleanUp() }
        try fixture.newBytes.write(to: fixture.stagingURL)
        try fixture.journal().begin(fixture.pending())
        let other = fixture.directory.appendingPathComponent("some-other.sqlite")
        try fixture.oldBytesRequired().write(to: other)

        #expect(throws: MedicalCatalogActivationJournal.Failure.invalidState) {
            try fixture.journal().recoverBeforeOpen(catalogURL: other)
        }
    }
}

// MARK: - Fixture

private struct JournalFixture {
    let directory: URL
    let activeURL: URL
    let stagingURL: URL
    let backupURL: URL
    let patientURL: URL
    let candidate: VerifiedMedicalCatalogCandidate
    let newBytes: Data
    let oldBytes: Data?

    var journalURL: URL { directory.appendingPathComponent("medical-catalog-activation.journal.json") }

    static func make(hadActive: Bool) throws -> JournalFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("medical-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let active = directory.appendingPathComponent("medical-catalog.sqlite")
        let staging = directory.appendingPathComponent("medical-catalog-staging-\(UUID().uuidString).sqlite")
        let patient = directory.appendingPathComponent("vitaliber.sqlite")
        try Data("patient main database — never touched".utf8).write(to: patient)

        let expected = try GoMedicalFixture.expected()
        let pointer = try GoMedicalFixture.data(expected.installablePointer)
        let expectation = try GoMedicalFixture.expectation(pointer, servedAs: expected.installablePointer)
        let candidate = VerifiedMedicalCatalogCandidate(verified: expectation)
        let newBytes = try GoMedicalFixture.data("catalog.sqlite")

        var oldBytes: Data?
        if hadActive {
            let old = Data("SQLite format 3\u{0}".utf8) + Data("OLD-CATALOG-FIXTURE".utf8)
            try old.write(to: active)
            oldBytes = old
        }
        return JournalFixture(directory: directory, activeURL: active, stagingURL: staging,
                              backupURL: active.deletingLastPathComponent()
                                  .appendingPathComponent(active.lastPathComponent + MedicalCatalogUpdateService.lastGoodSuffix),
                              patientURL: patient, candidate: candidate, newBytes: newBytes, oldBytes: oldBytes)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory) // try?-ok: 隔离测试目录清理
    }

    func oldBytesRequired() throws -> Data {
        try #require(oldBytes)
    }

    func journal(verifyInstalled: (@Sendable (URL, Int, String) throws -> Void)? = nil) -> MedicalCatalogActivationJournal {
        MedicalCatalogActivationJournal(
            journalURL: journalURL, supportDirectory: directory,
            sha256: { url in ReferenceSHA256().sha256Hex(try Data(contentsOf: url)) },
            verifyInstalled: verifyInstalled)
    }

    func pending() -> PendingActivation {
        PendingActivation(candidate: candidate, stagingURL: stagingURL, activeURL: activeURL,
                          lastGoodBackupURL: oldBytes != nil ? backupURL : nil)
    }

    func hash(_ url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return ReferenceSHA256().sha256Hex(data)
    }

    func hash(_ data: Data) -> String { ReferenceSHA256().sha256Hex(data) }

    func patientUnchanged() -> Bool {
        hash(patientURL) == hash(Data("patient main database — never touched".utf8))
    }
}
