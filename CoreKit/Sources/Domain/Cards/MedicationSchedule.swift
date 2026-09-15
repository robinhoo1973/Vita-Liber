import Foundation

public struct MedicationScheduleCard: InformationCard {
    public static let cardType = "medication_schedule"

    public var cardId: String = UUID().uuidString
    public var patientId: String?
    public var source: DataSource = .manual
    public var confidence: Double = 1.0
    public var fieldConfidence: [String: Double] = [:]
    public var rawText: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var prescriptionId: String?
    public var planName: String?
    public var planStartDate: Date = Date()
    public var planEndDate: Date?
    public var remindTimePoints: [String] = []
    public var remindMethod: String?
    public var status: ScheduleStatus = .active
    public var drugs: [MedicationPlanDrug] = []

    public init() {}
}

public enum ScheduleStatus: String, Codable, Sendable {
    case active  = "0"
    case paused  = "1"
    case done    = "2"
    case stopped = "3"
}

public struct MedicationPlanDrug: Codable, Sendable, Identifiable {
    public var planDrugId: String = UUID().uuidString
    public var guideId: String
    public var timePointLabel: String?
    public var takeTime: String
    public var dosageThisTime: String
    public var seqNo: Int?

    public init(guideId: String, takeTime: String, dosageThisTime: String) {
        self.guideId = guideId
        self.takeTime = takeTime
        self.dosageThisTime = dosageThisTime
    }
}
