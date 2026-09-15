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
}

extension JSONEncoder {
    public static var iso8601: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    public static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
