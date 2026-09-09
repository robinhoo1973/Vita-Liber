import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
@testable import VitaLiber

// binds: SU-M1c-FR14 (BR-010, permission reload must not undo an in-flight revoke)
@MainActor
final class AuthorizationReloadTests: XCTestCase {
    func test_failedDenialStaysClosedUntilAnExplicitGrant() async throws {
        let db = try GRDBStore.inMemory()
        let settings = AppSettingsStore(store: SettingsStore(writer: db.writer))
        await settings.load()
        try await db.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_authorization_write BEFORE INSERT ON app_settings WHEN NEW.key = 'authAI' BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }
        await settings.set("false", for: .authAI)
        let deniedRevision = settings.authAIRevision
        await settings.load()
        XCTAssertEqual(settings.values[.authAI], "false")
        XCTAssertEqual(settings.authAIRevision, deniedRevision)
        try await db.writer.write { try $0.execute(sql: "DROP TRIGGER fail_authorization_write") }
        await settings.set("true", for: .authAI)
        XCTAssertEqual(settings.values[.authAI], "true")
        XCTAssertGreaterThan(settings.authAIRevision, deniedRevision)
    }

    func test_WALReloadCannotReplaceAnOutstandingDenial() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("authorization-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // try?-ok: temporary test data cleanup
        let pool = try DatabasePool(path: directory.appendingPathComponent("settings.sqlite").path)
        defer { try? pool.close() } // try?-ok: test cleanup preserves any earlier failure
        try await pool.write { db in
            try db.execute(sql: "CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO app_settings VALUES ('authAI', 'true')")
        }
        let settings = AppSettingsStore(store: SettingsStore(writer: pool))
        await settings.load()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let blocked = Task.detached {
            try await pool.write { _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        let didEnter = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 2) == .success) }
        }
        XCTAssertTrue(didEnter)
        let revoking = Task { await settings.set("false", for: .authAI) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while settings.values[.authAI] != "false", ContinuousClock.now < deadline { await Task.yield() }
        let revision = settings.authAIRevision
        await settings.load()
        XCTAssertEqual(settings.values[.authAI], "false")
        XCTAssertEqual(settings.authAIRevision, revision)
        release.signal()
        try await blocked.value
        await revoking.value
        XCTAssertEqual(settings.values[.authAI], "false")
        let persisted = try await pool.read { try String.fetchOne($0, sql: "SELECT value FROM app_settings WHERE key = 'authAI'") }
        XCTAssertEqual(persisted, "false")
    }
}
