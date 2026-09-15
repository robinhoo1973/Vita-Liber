import Foundation

public struct PatientRecord: InformationCard {
    public static let cardType = "patient"

    public var cardId: String = UUID().uuidString
    public var patientId: String?
    public var source: DataSource = .manual
    public var confidence: Double = 1.0
    public var fieldConfidence: [String: Double] = [:]
    public var rawText: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var name: String?
    public var gender: String?
    public var birthDate: Date?
    public var idNumber: String?
    public var healthCardNo: String?
    public var phone: String?
    public var ethnicity: String?
    public var allergyHistory: String?
    public var aboBloodType: String?
    public var rhBloodType: String?

    public init() {}
}
