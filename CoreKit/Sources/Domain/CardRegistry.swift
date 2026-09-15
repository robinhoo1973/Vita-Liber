import Foundation

public final class CardRegistry: @unchecked Sendable {
    public static let shared = CardRegistry()

    private var types: [String: (Data) throws -> AnyCard] = [:]
    private let lock = NSLock()

    public func register<C: InformationCard>(_ type: C.Type) {
        lock.lock(); defer { lock.unlock() }
        types[C.cardType] = { data in
            try AnyCard(try JSONDecoder.iso8601.decode(C.self, from: data))
        }
    }

    public func decode(cardType: String, payload: Data) throws -> AnyCard {
        lock.lock(); let decoder = types[cardType]; lock.unlock()
        guard let decoder else {
            throw CardError.unknownCardType(cardType)
        }
        return try decoder(payload)
    }
}
