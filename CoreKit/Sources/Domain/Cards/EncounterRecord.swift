import Foundation

public struct EncounterRecord: InformationCard {
    public static let cardType = "encounter"

    public var cardId: String = UUID().uuidString
    public var patientId: String?
    public var source: DataSource = .manual
    public var confidence: Double = 1.0
    public var fieldConfidence: [String: Double] = [:]
    public var rawText: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var visitType: VisitType = .firstVisit
    public var visitDate: Date = Date()
    public var department: String?
    public var doctorName: String?
    public var chiefComplaint: String?
    public var diagnosis: String?
    public var treatmentPlan: String?

    public init() {}
}
