import Foundation

public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public static func from(_ value: Any?) -> SQLiteValue {
        switch value {
        case nil:                    return .null
        case let v as Int:           return .integer(Int64(v))
        case let v as Int64:         return .integer(v)
        case let v as Double:        return .real(v)
        case let v as Float:         return .real(Double(v))
        case let v as String:        return .text(v)
        case let v as Data:          return .blob(v)
        case let v as Date:          return .real(v.timeIntervalSince1970)
        case let v as Bool:          return .integer(v ? 1 : 0)
        case let v as UUID:          return .text(v.uuidString)
        default:                     return .text(String(describing: value))
        }
    }

    public var string: String? {
        if case .text(let v) = self { return v }
        return nil
    }

    public var int: Int64? {
        switch self {
        case .integer(let v): return v
        case .real(let v):    return Int64(v)
        case .text(let v):    return Int64(v)
        default:              return nil
        }
    }

    public var double: Double? {
        switch self {
        case .real(let v):    return v
        case .integer(let v): return Double(v)
        case .text(let v):    return Double(v)
        default:              return nil
        }
    }

    public var bool: Bool? {
        if case .integer(let v) = self { return v != 0 }
        return nil
    }

    public var data: Data? {
        if case .blob(let v) = self { return v }
        return nil
    }

    public var date: Date? {
        guard let ts = double else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    func `as`<T>(_ type: T.Type) -> T? {
        switch type {
        case is String.Type:  return string as? T
        case is Int.Type:     return int.map(Int.init) as? T
        case is Int64.Type:   return int as? T
        case is Double.Type:  return double as? T
        case is Bool.Type:    return bool as? T
        case is Data.Type:    return data as? T
        case is Date.Type:    return date as? T
        default:              return nil
        }
    }
}

public protocol DatabaseProtocol: Sendable {
    func execute(_ sql: String, params: [SQLiteValue]) throws
    func query(_ sql: String, params: [SQLiteValue]) throws -> [[String: SQLiteValue]]
    func queryScalar<T>(_ sql: String, params: [SQLiteValue]) throws -> T?
    func transaction<T>(_ block: () throws -> T) throws -> T
}

public extension DatabaseProtocol {
    func execute(_ sql: String) throws { try execute(sql, params: []) }
    func query(_ sql: String) throws -> [[String: SQLiteValue]] { try query(sql, params: []) }
}
