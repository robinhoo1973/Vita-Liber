import Foundation

public struct PrescriptionRecord: InformationCard {
    public static let cardType = "prescription"

    public var cardId: String = UUID().uuidString
    public var patientId: String?
    public var source: DataSource = .manual
    public var confidence: Double = 1.0
    public var fieldConfidence: [String: Double] = [:]
    public var rawText: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var prescriptionNo: String?
    public var hospitalName: String?
    public var department: String?
    public var doctorName: String?
    public var prescriptionDate: Date?
    public var diagnosis: String?
    public var items: [PrescriptionItem] = []

    public init() {}
}

public struct PrescriptionItem: Codable, Sendable, Identifiable {
    public var itemId: String = UUID().uuidString
    public var drugName: String
    public var dosage: String?
    public var unit: String?
    public var frequency: String?
    public var route: String?
    public var days: Int?
    public var quantity: String?
    public var note: String?

    public init(drugName: String) {
        self.drugName = drugName
    }
}
