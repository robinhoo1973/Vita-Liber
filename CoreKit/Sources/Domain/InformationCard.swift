import Foundation

public protocol InformationCard: Codable, Sendable, Identifiable {
    static var cardType: String { get }
    static var schemaVersion: Int { get }
    var cardId: String { get set }
    var patientId: String? { get set }
    var source: DataSource { get set }
    var confidence: Double { get set }
    var fieldConfidence: [String: Double] { get set }
    var rawText: String? { get set }
    var createdAt: Date { get set }
    var updatedAt: Date { get set }
}

public extension InformationCard {
    static var schemaVersion: Int { 1 }
    var id: String { cardId }
}
