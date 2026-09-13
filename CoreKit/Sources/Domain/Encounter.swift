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
    // v25（子项目 D §C.1）门诊病历叙事列：原文保存，不摘要不改写；allergy_history 为资料建议（D4）来源。
    public var presentIllness: String?
    public var visitSummary: String?
    public var pastHistory: String?
    public var physicalExam: String?
    public var allergyHistory: String?
    public init(id: UUID = UUID(), patientId: UUID, date: Date = Date(), kind: String = EncounterKind.outpatient.rawValue,
                hospital: String? = nil, department: String? = nil, doctor: String? = nil,
                chiefComplaint: String? = nil, diagnosisText: String? = nil,
                adviceText: String? = nil, followUpRequirement: String? = nil,
                feeAmount: Double? = nil,
                presentIllness: String? = nil, visitSummary: String? = nil, pastHistory: String? = nil,
                physicalExam: String? = nil, allergyHistory: String? = nil) {
        self.id = id; self.patientId = patientId; self.date = date; self.kind = kind
        self.hospital = hospital; self.department = department; self.doctor = doctor
        self.chiefComplaint = chiefComplaint; self.diagnosisText = diagnosisText
        self.adviceText = adviceText; self.followUpRequirement = followUpRequirement
        self.feeAmount = feeAmount
        self.presentIllness = presentIllness; self.visitSummary = visitSummary; self.pastHistory = pastHistory
        self.physicalExam = physicalExam; self.allergyHistory = allergyHistory
    }
}

/// FR4.1 就诊类型（门诊/急诊/住院/体检/互联网问诊/复诊）
public enum EncounterKind: String, Sendable, CaseIterable, Codable {
    case outpatient, emergency, inpatient, checkup, telemedicine, followup
}
