#if os(iOS) || os(macOS)
// linux-blind: GRDB only links on iOS/macOS; Linux compiles an empty unit.
import Foundation
import GRDB
import os

/// One-time physical database rename.  The App has always used
/// `vitaliber.sqlite`; the canonical name is now
/// `app-local-user_data.sqlite`.  Checkpoint WAL first, then move the sealed
/// file and remove the legacy sidecars.  The caller keeps the old path on any
/// failure so a migration error never silently creates an empty database.
public enum DatabaseFileMigration {
    public enum Failure: LocalizedError {
        case sourceMissing
        case targetExists
        case notSealed(String)
        case moveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sourceMissing: return "legacy database is missing"
            case .targetExists: return "canonical database already exists"
            case .notSealed(let detail): return "legacy database could not be sealed: \(detail)"
            case .moveFailed(let detail): return "legacy database could not be moved: \(detail)"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.vitaliber", category: "database-migration")

    public static func migrate(from source: URL, to target: URL,
                               fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: source.path) else { throw Failure.sourceMissing }
        guard !fileManager.fileExists(atPath: target.path) else { throw Failure.targetExists }

        // Seal WAL before moving.  Opening and closing through GRDB also proves
        // the source is a readable SQLite database, not a partial file.
        do {
            let queue = try DatabaseQueue(path: source.path)
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode=DELETE")
                guard mode?.lowercased() == "delete" else { throw Failure.notSealed("journal_mode=\(mode ?? "nil")") }
            }
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.notSealed(String(describing: error))
        }

        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try? fileManager.removeItem(at: sidecar) // try?-ok: sealed DB owns no sidecar
            }
        }

        do {
            try fileManager.moveItem(at: source, to: target)
        } catch {
            throw Failure.moveFailed(String(describing: error))
        }
        let attributes = try? fileManager.attributesOfItem(atPath: target.path) // try?-ok: 取不到属性≠空文件
        // -1 = attributes unavailable; only a known zero size proves the move
        // produced an empty database.  Never roll back a healthy move because
        // the metadata read failed.
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        guard size != 0 else {
            // Roll back if the moved file is visibly empty.
            try? fileManager.moveItem(at: target, to: source) // try?-ok: best-effort rollback
            throw Failure.moveFailed("moved database is empty")
        }
        if size < 0 {
            logger.warning("database migrated but size could not be verified: \(target.path, privacy: .public)")
        }
        logger.info("database migrated: vitaliber.sqlite -> app-local-user_data.sqlite")
    }
}
#endif
