import Foundation
import GRDB
import Domain
import Protocols

public final class GRDBEngine: DatabaseProtocol, @unchecked Sendable {

    private var dbQueue: DatabaseQueue?
    private let queue = DispatchQueue(label: "com.vitaliber.db.engine", qos: .userInitiated)

    public init() {}

    public func setup(path: String) throws {
        try queue.sync {
            var config = Configuration()
            config.readonly = false
            config.allowsUnsafeTransactions = true
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA busy_timeout = 5000")
            }
            dbQueue = try DatabaseQueue(path: path, configuration: config)
        }
    }

    public func setupInMemory() throws {
        try queue.sync {
            var config = Configuration()
            config.allowsUnsafeTransactions = true
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            dbQueue = try DatabaseQueue(configuration: config)
        }
    }

    public func execute(_ sql: String, params: [SQLiteValue]) throws {
        try queue.sync {
            guard let dbQueue else { throw SQLiteError.notOpened }
            try dbQueue.write { db in
                try db.execute(sql: sql, arguments: grdbArguments(params))
            }
        }
    }

    public func query(_ sql: String, params: [SQLiteValue]) throws -> [[String: SQLiteValue]] {
        try queue.sync {
            guard let dbQueue else { throw SQLiteError.notOpened }
            return try dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: sql, arguments: grdbArguments(params))
                return rows.map { row in
                    var dict: [String: SQLiteValue] = [:]
                    for (index, column) in row.columnNames.enumerated() {
                        dict[column] = sqliteValue(from: row, at: index)
                    }
                    return dict
                }
            }
        }
    }

    public func queryScalar<T>(_ sql: String, params: [SQLiteValue]) throws -> T? {
        try queue.sync {
            guard let dbQueue else { throw SQLiteError.notOpened }
            return try dbQueue.read { db in
                let row = try Row.fetchOne(db, sql: sql, arguments: grdbArguments(params))
                guard let first = row?.first else { return nil }
                return sqliteValue(from: row!, at: 0).as(T.self)
            }
        }
    }

    public func transaction<T>(_ block: () throws -> T) throws -> T {
        try queue.sync {
            guard let dbQueue else { throw SQLiteError.notOpened }
            return try dbQueue.write { db in
                try block()
            }
        }
    }

    private func grdbArguments(_ params: [SQLiteValue]) -> StatementArguments {
        StatementArguments(params.map { value -> any DatabaseValueConvertible in
            switch value {
            case .null:     return nil as DatabaseValueConvertible?
            case .integer(let v): return v
            case .real(let v):    return v
            case .text(let v):    return v
            case .blob(let v):    return v
            }
        })
    }

    private func sqliteValue(from row: Row, at index: Int) -> SQLiteValue {
        let dbValue = row[index]
        switch dbValue.storage {
        case .null:     return .null
        case .int64(let v):  return .integer(v)
        case .double(let v): return .real(v)
        case .string(let v): return .text(v)
        case .blob(let v):   return .blob(v)
        }
    }
}
