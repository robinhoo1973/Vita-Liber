import Foundation

public enum SQLiteError: Error, Sendable {
    case notOpened
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String, code: Int32)
    case execFailed(String)
    case bindFailed(String)
    case migrationFailed(String)
    case migrationVersionMismatch(current: Int, expected: Int)
    case unknown

    public var isBusy: Bool {
        if case .stepFailed(_, let code) = self {
            return code == 5 || code == 6
        }
        return false
    }

    public var isCorrupted: Bool {
        if case .stepFailed(_, let code) = self {
            return code == 11
        }
        return false
    }
}

public enum RepositoryError: Error, Sendable {
    case invalidId
    case notFound(id: String)
    case fieldTooLong(String)
    case constraintViolation(String)
    case concurrentModification
    case unsupportedOperation(String)
}

public enum CardError: Error, Sendable {
    case unknownCardType(String)
    case decodeFailed(String)
    case encodeFailed(String)
    case schemaVersionMismatch(String)
}
