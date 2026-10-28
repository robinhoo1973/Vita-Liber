import Foundation

public struct PatientProfile: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public var displayName: String
    /// §4.3 v2 列（V3.40 建全表后入库需要）：relation 必填；其余可空。
    public var relation: String
    public var gender: String?
    public var birthDate: String?
    /// FR3.1 P0 字段：血型（证件号/医保号已于 2026-10-22 彻底移除；头像 P1 可选）
    public var bloodType: String?
    /// FR3.1 P1 字段（2026-10-28 补录批；v50 迁移）：身高/体重=当前测量值
    /// （FR21.9 ④「影响药物剂量计算·可在个人中心补全」）。不参与完善度口径
    /// （完善度只计血型+生日）。
    public var heightCm: Double?
    public var weightKg: Double?
    public var note: String?
    public var createdAt: TimeInterval
    public var updatedAt: TimeInterval
    /// 软删时间戳（nil = 活跃成员）——第六轮全仓审查修复：备份/恢复
    /// 必须随包往返软删状态，否则已删成员在换机恢复后被复活为活跃行。
    public var deletedAt: TimeInterval?
    public init(id: UUID = UUID(), displayName: String, relation: String = "本人",
                gender: String? = nil, birthDate: String? = nil,
                bloodType: String? = nil,
                heightCm: Double? = nil, weightKg: Double? = nil,
                note: String? = nil,
                createdAt: TimeInterval = 0, updatedAt: TimeInterval = 0,
                deletedAt: TimeInterval? = nil) {
        self.id = id; self.displayName = displayName; self.relation = relation
        self.gender = gender; self.birthDate = birthDate
        self.bloodType = bloodType
        self.heightCm = heightCm; self.weightKg = weightKg
        self.note = note
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// FR5.8/§5.3 字段确认状态机（最小切片：ocrUnconfirmed → confirmed）
public enum FieldConfirmation: Sendable, Equatable, Codable {
    case ocrUnconfirmed, confirmed, rejected
    public mutating func confirm() { guard self == .ocrUnconfirmed else { return }; self = .confirmed }
    public var isUsableInTimeline: Bool { self == .confirmed }   // BR-003 最小验证
}
