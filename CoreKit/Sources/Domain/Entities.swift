import Foundation

public struct PatientProfile: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public var displayName: String
    /// §4.3 v2 列（V3.40 建全表后入库需要）：relation 必填；其余可空。
    public var relation: String
    public var gender: String?
    public var birthDate: String?
    /// FR3.1 P0 字段：血型 / 证件号 / 医保号（头像 P1 可选）
    public var bloodType: String?
    public var idNo: String?
    public var insuranceNo: String?
    public var note: String?
    public var createdAt: TimeInterval
    public var updatedAt: TimeInterval
    public init(id: UUID = UUID(), displayName: String, relation: String = "本人",
                gender: String? = nil, birthDate: String? = nil,
                bloodType: String? = nil, idNo: String? = nil, insuranceNo: String? = nil,
                note: String? = nil,
                createdAt: TimeInterval = 0, updatedAt: TimeInterval = 0) {
        self.id = id; self.displayName = displayName; self.relation = relation
        self.gender = gender; self.birthDate = birthDate
        self.bloodType = bloodType; self.idNo = idNo; self.insuranceNo = insuranceNo
        self.note = note
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// FR5.8/§5.3 字段确认状态机（最小切片：ocrUnconfirmed → confirmed）
public enum FieldConfirmation: Sendable, Equatable, Codable {
    case ocrUnconfirmed, confirmed, rejected
    public mutating func confirm() { guard self == .ocrUnconfirmed else { return }; self = .confirmed }
    public var isUsableInTimeline: Bool { self == .confirmed }   // BR-003 最小验证
}
