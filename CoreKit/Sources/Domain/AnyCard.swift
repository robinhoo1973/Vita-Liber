import Foundation

public struct AnyCard: Codable, Sendable {
    public let cardType: String
    public let schemaVersion: Int
    public let payload: Data

    public init<C: InformationCard>(_ card: C) throws {
        self.cardType = C.cardType
        self.schemaVersion = C.schemaVersion
        self.payload = try JSONEncoder.iso8601.encode(card)
    }

    public func decode<C: InformationCard>(as type: C.Type) throws -> C {
        try JSONDecoder.iso8601.decode(C.self, from: payload)
    }

    public var cardId: String? {
        (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["cardId"] as? String  // try?-ok: best-effort JSON field extraction, nil on any error
    }
}
