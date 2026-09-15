import Foundation

public struct MedicationGuide: InformationCard {
    public static let cardType = "medication_guide"

    public var cardId: String = UUID().uuidString
    public var patientId: String?
    public var source: DataSource = .manual
    public var confidence: Double = 1.0
    public var fieldConfidence: [String: Double] = [:]
    public var rawText: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var drugCode: String = ""
    public var drugName: String = ""
    public var dosagePerTime: String = ""
    public var dosageUnit: String?
    public var administrationRoute: String?
    public var takeTiming: String = ""
    public var specialPrecautions: String?
    public var adverseReactionTip: String?
    public var storageRequirement: String?
    public var maxDailyDose: String?
    public var minIntervalHours: Double?
    public var foodInteraction: String?

    public init() {}
}
