import Foundation

public struct DocumentFile: Sendable, Equatable, Codable {
    public let id: UUID
    public let patientId: UUID
    public var title: String?
    public init(id: UUID = UUID(), patientId: UUID, title: String?) {
        self.id = id; self.patientId = patientId; self.title = title
    }
}

public struct MedicationPlan: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable { case active, paused, ended }
    public let id: UUID
    public let patientId: UUID
    public var drugName: String
    public var status: Status
    public init(id: UUID = UUID(), patientId: UUID, drugName: String, status: Status = .active) {
        self.id = id; self.patientId = patientId; self.drugName = drugName; self.status = status
    }
}

/// tech §3：Preview/单测统一数据工厂（禁连生产库）
public enum MockFactory {
    public static func patient(name: String = "王女士") -> PatientProfile {
        PatientProfile(displayName: name)
    }
    public static func document(for p: PatientProfile, title: String = "门诊病历") -> DocumentFile {
        DocumentFile(patientId: p.id, title: title)
    }
    public static func plan(for p: PatientProfile, drug: String = "阿莫西林") -> MedicationPlan {
        MedicationPlan(patientId: p.id, drugName: drug)
    }
}
