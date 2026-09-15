import Foundation

public final class RetryingDatabase: DatabaseProtocol, @unchecked Sendable {
    private let inner: any DatabaseProtocol
    private let maxRetries: Int
    private let baseDelay: TimeInterval

    public init(inner: any DatabaseProtocol, maxRetries: Int = 3, baseDelay: TimeInterval = 0.1) {
        self.inner = inner
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
    }

    public func execute(_ sql: String, params: [SQLiteValue]) throws {
        try retry { try inner.execute(sql, params: params) }
    }

    public func query(_ sql: String, params: [SQLiteValue]) throws -> [[String: SQLiteValue]] {
        try retry { try inner.query(sql, params: params) }
    }

    public func queryScalar<T>(_ sql: String, params: [SQLiteValue]) throws -> T? {
        try retry { try inner.queryScalar(sql, params: params) }
    }

    public func transaction<T>(_ block: () throws -> T) throws -> T {
        try retry { try inner.transaction(block) }
    }

    private func retry<T>(_ block: () throws -> T) throws -> T {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                return try block()
            } catch let e as SQLiteError where e.isBusy {
                lastError = e
                let delay = baseDelay * pow(2.0, Double(attempt))
                Thread.sleep(forTimeInterval: delay)
            }
        }
        throw lastError ?? SQLiteError.unknown
    }
}
