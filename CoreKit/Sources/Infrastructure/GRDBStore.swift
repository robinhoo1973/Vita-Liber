import Foundation
import GRDB
import Domain

/// M0 · SchemaV1 装配（§4.3/§5.4）：外键强制开启，DDL 引用完整性由 MigrationEngine.schemaV1 提供
public struct GRDBStore {
    public let dbQueue: DatabaseQueue
    public init(inMemory: Bool = true) throws {
        dbQueue = try DatabaseQueue()
        var config = Configuration(); config.foreignKeysEnabled = true
        _ = config
        try dbQueue.write { db in
            try db.execute(sql: MigrationEngine.schemaV1)
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
    }
    public func insert(profile: PatientProfile) throws {
        try dbQueue.write { try $0.execute(sql: "INSERT INTO patient_profile VALUES (?,?)", arguments: [profile.id.uuidString, profile.displayName]) }
    }
    public var foreignKeysOn: Bool { (try? dbQueue.read { try BooleanGrabber().fetchOne($0, sql: "PRAGMA foreign_keys") }) ?? false }
}
struct BooleanGrabber: FetchableRecord { let v: Int; init(row: Row) { v = row[0] }; static func fetchOne(_ db: Database, sql: String) throws -> Bool? { try Row.fetchOne(db, sql: sql).map { Row(row: $0)[0] as Int == 1 } } }
