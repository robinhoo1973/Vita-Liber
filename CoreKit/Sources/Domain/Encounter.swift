import Foundation

/// F4 就诊草稿（FR4.1 字段全集；Domain 层实体，EncounterStore 消费）。
/// 就诊类型枚举值同时约束 UI 选择器与落库 kind。
public struct EncounterDraft: Sendable, Equatable {
    public var id: UUID
    public var patientId: UUID
    public var date: Date
    public var kind: String
    public var hospital: String?
    public var department: String?
    public var doctor: String?
    public var chiefComplaint: String?
    public var diagnosisText: String?
    public var adviceText: String?
    public var followUpRequirement: String?
    public var feeAmount: Double?
    public init(id: UUID = UUID(), patientId: UUID, date: Date = Date(), kind: String = "门诊",
                hospital: String? = nil, department: String? = nil, doctor: String? = nil,
                chiefComplaint: String? = nil, diagnosisText: String? = nil,
                adviceText: String? = nil, followUpRequirement: String? = nil,
                feeAmount: Double? = nil) {
        self.id = id; self.patientId = patientId; self.date = date; self.kind = kind
        self.hospital = hospital; self.department = department; self.doctor = doctor
        self.chiefComplaint = chiefComplaint; self.diagnosisText = diagnosisText
        self.adviceText = adviceText; self.followUpRequirement = followUpRequirement
        self.feeAmount = feeAmount
    }
}

/// FR4.1 就诊类型（门诊/急诊/住院/体检/互联网问诊/复诊）
public enum EncounterKind: String, Sendable, CaseIterable, Codable {
    case outpatient, emergency, inpatient, checkup, telemedicine, followup
}
