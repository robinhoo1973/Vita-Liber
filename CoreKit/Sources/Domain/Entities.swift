import Foundation

public struct PatientProfile: Sendable, Equatable, Codable {
    public let id: UUID
    public var displayName: String
    public init(id: UUID = UUID(), displayName: String) { self.id = id; self.displayName = displayName }
}

/// FR5.8/§5.3 字段确认状态机（最小切片：ocrUnconfirmed → confirmed）
public enum FieldConfirmation: Sendable, Equatable, Codable {
    case ocrUnconfirmed, confirmed, rejected
    public mutating func confirm() { guard self == .ocrUnconfirmed else { return }; self = .confirmed }
    public var isUsableInTimeline: Bool { self == .confirmed }   // BR-003 最小验证
}
