import Foundation

/// FR6.9: versioned, lossless D-grade snapshot. Never exported as clinical facts.
public struct PendingCardPayload: Codable, Sendable, Equatable {
    public var card: MatchedCard?
    private var legacyShared: [String: String]
    private var legacyRows: [[String: String]]

    /// Read-only value projections for existing draft summaries, not an editing surface.
    public var shared: [String: String] {
        guard let card else { return legacyShared }
        return Dictionary(card.shared.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }
    public var rows: [[String: String]] {
        guard let card else { return legacyRows }
        return card.rows.map { row in
            Dictionary(row.fields.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
    }

    public init(shared: [String: String] = [:], rows: [[String: String]] = []) {
        card = nil; legacyShared = shared; legacyRows = rows
    }

    public init(card: MatchedCard) {
        self.card = card; legacyShared = [:]; legacyRows = []
    }

    public enum PayloadError: Error, Sendable { case corrupt, identityMismatch }

    public static func decode(_ json: String, cardKind: String? = nil) throws -> PendingCardPayload {
        do {
            var payload = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
            if payload.card == nil, payload.legacyRows.isEmpty, let cardKind {
                let rowKeys: Set<String>
                switch cardKind {
                case "prescription": rowKeys = ["drug_name"]
                case "metric_sample": rowKeys = ["raw_label", "value", "unit", "metric_key", "ref_low", "ref_high"]
                case "medication": rowKeys = ["generic_name", "unit_kind", "brand_name", "spec", "drug_key"]
                default: rowKeys = []
                }
                let row = payload.legacyShared.filter { rowKeys.contains($0.key) }
                if !row.isEmpty {
                    payload.legacyRows = [row]
                    for key in row.keys { payload.legacyShared.removeValue(forKey: key) }
                }
            }
            if let cardKind, let card = payload.card, card.kind != cardKind { throw PayloadError.identityMismatch }
            return payload
        } catch let error as PayloadError {
            throw error
        } catch {
            throw PayloadError.corrupt
        }
    }

    /// The database pending ID supplies stable identity for pre-v22 snapshots.
    /// A missing legacy page must be resolved by the caller, not silently assumed to be zero.
    public func matchedCard(kind: String, pageIndex: Int, id: UUID) throws -> MatchedCard {
        guard pageIndex >= 0 else { throw PayloadError.identityMismatch }
        if let card {
            guard card.kind == kind, card.pageIndex == pageIndex else { throw PayloadError.identityMismatch }
            return card
        }
        func fields(_ values: [String: String]) -> [FieldDraft] {
            values.sorted { $0.key < $1.key }.map { FieldDraft(key: $0.key, value: $0.value, confidence: 0) }
        }
        let shared = fields(legacyShared)
        let sourceRows = legacyRows.isEmpty && kind == "encounter" ? [[:]] : legacyRows
        let rows = sourceRows.enumerated().map { index, values in
            var bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
            for i in 0..<8 { bytes[15 - i] ^= UInt8(truncatingIfNeeded: UInt64(index + 1) >> (i * 8)) }
            let rowID = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            return MatchedCardRow(id: rowID, fields: fields(values))
        }
        let rules = CompletenessEvaluator.rules(for: kind)
        let covered = Set((shared + rows.flatMap(\.fields)).filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map(\.key))
        let required = rules.filter(\.isRequired)
        return MatchedCard(id: id, kind: kind, pageIndex: pageIndex, shared: shared, rows: rows,
                          allFieldCoverage: rules.isEmpty ? 0 : Double(covered.intersection(rules.map(\.key)).count) / Double(rules.count),
                          requiredCoverage: required.isEmpty ? 0 : Double(required.filter { covered.contains($0.key) }.count) / Double(required.count),
                          missingRequired: required.filter { !covered.contains($0.key) },
                          level: CompletenessEvaluator.assess(fields: shared + (rows.first?.fields ?? []), cardKind: kind).level)
    }

    public var json: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, card, shared, rows }

    private static func validate(_ card: MatchedCard) throws {
        guard card.pageIndex >= 0, !card.rows.isEmpty, Set(card.rows.map(\.id)).count == card.rows.count,
              card.allFields.allSatisfy({ $0.confidence.isFinite && (0...1).contains($0.confidence) }) else { throw PayloadError.corrupt }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.schemaVersion) {
            guard try c.decode(Int.self, forKey: .schemaVersion) == 2 else { throw PayloadError.corrupt }
            let snapshot = try c.decode(MatchedCard.self, forKey: .card)
            try Self.validate(snapshot)
            card = snapshot
            legacyShared = [:]; legacyRows = []
        } else if c.contains(.shared) || c.contains(.rows) {
            card = nil
            legacyShared = try c.decode([String: String].self, forKey: .shared)
            legacyRows = try c.decode([[String: String]].self, forKey: .rows)
        } else {
            card = nil
            legacyShared = try decoder.singleValueContainer().decode([String: String].self)
            legacyRows = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let card {
            try Self.validate(card)
            try c.encode(2, forKey: .schemaVersion)
            try c.encode(card, forKey: .card)
        } else {
            try c.encode(legacyShared, forKey: .shared)
            try c.encode(legacyRows, forKey: .rows)
        }
    }
}
