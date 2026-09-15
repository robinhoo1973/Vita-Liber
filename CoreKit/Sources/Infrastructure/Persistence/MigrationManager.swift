import Foundation

public protocol Migration: Sendable {
    var version: Int { get }
    var name: String { get }
    func up(_ db: any DatabaseProtocol) throws
}

public final class MigrationManager: @unchecked Sendable {
    private let db: any DatabaseProtocol
    private var migrations: [Migration] = []
    private let lock = NSLock()

    public init(db: any DatabaseProtocol) {
        self.db = db
    }

    public func register(_ migration: Migration) {
        lock.lock(); defer { lock.unlock() }
        guard !migrations.contains(where: { $0.version == migration.version }) else { return }
        migrations.append(migration)
        migrations.sort { $0.version < $1.version }
    }

    public func registerAll(_ list: [Migration]) {
        list.forEach(register)
    }

    public func migrateIfNeeded() throws {
        lock.lock(); let sorted = migrations; lock.unlock()
        let current = try currentVersion()
        let target = sorted.last?.version ?? 0
        guard current < target else { return }

        for m in sorted where m.version > current {
            do {
                try db.transaction {
                    try m.up(db)
                    try setVersion(m.version)
                }
            } catch {
                throw SQLiteError.migrationFailed("v\(m.version)-\(m.name): \(error)")
            }
        }
    }

    private func currentVersion() throws -> Int {
        let v: Int64? = try db.queryScalar("PRAGMA user_version;")
        return Int(v ?? 0)
    }

    private func setVersion(_ v: Int) throws {
        try db.execute("PRAGMA user_version = \(v);")
    }
}
