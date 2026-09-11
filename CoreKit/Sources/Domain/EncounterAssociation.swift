import Foundation

/// 卡内选择只在用户保存卡后成为关系。none不能与尚未选择合并，避免后续偷偷回填。
public enum EncounterAssociation: Codable, Sendable, Equatable {
    case unselected
    case none
    case existing(UUID)
    case suggested(UUID, evidence: String)
    public var encounterID: UUID? {
        switch self { case .existing(let id), .suggested(let id, _): return id; default: return nil }
    }
}

public enum EncounterResolver {
    public struct Candidate: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let patientId: UUID
        public let date: Date
        public let hospital: String?
        public let doctor: String?
        public init(id: UUID, patientId: UUID, date: Date, hospital: String?, doctor: String?) {
            self.id = id; self.patientId = patientId; self.date = date; self.hospital = hospital; self.doctor = doctor
        }
    }

    public static func suggest(date: Date?, hospital: String?, doctor: String?, patientId: UUID,
                               candidates: [Candidate], calendar: Calendar = .current) -> UUID? {
        guard let date, date.timeIntervalSince1970.isFinite, let hospital, !normalize(hospital).isEmpty else { return nil }
        let scored = candidates.compactMap { candidate -> (UUID, Int)? in
            guard candidate.patientId == patientId,
                  let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: candidate.date)).day,
                  abs(days) <= 3, let name = candidate.hospital else { return nil }
            let similarity = hospitalScore(hospital, name)
            guard similarity > 0 else { return nil }
            let doctorMatch = doctor.map { !normalize($0).isEmpty && normalize($0) == normalize(candidate.doctor ?? "") } ?? false
            return (candidate.id, similarity + (doctorMatch ? 2 : 0) + 3 - abs(days))
        }
        guard let best = scored.map(\.1).max() else { return nil }
        let winners = scored.filter { $0.1 == best }
        return winners.count == 1 ? winners[0].0 : nil
    }

    public static func evidenceKey(for card: MatchedCard) -> String {
        card.shared.filter { ["hospital", "merchant", "provider", "doctor", "date", "measured_at", "prescribed_at", "administered_at"].contains($0.key) }
            .map { $0.key + "=" + $0.value }.sorted().joined(separator: "\n")
    }

    public static func context(for card: MatchedCard) -> (date: Date?, hospital: String?, doctor: String?) {
        func value(_ keys: [String]) -> String? {
            card.shared.first { keys.contains($0.key) && $0.grade != .rejected }?.value
        }
        return (value(["date", "measured_at", "prescribed_at", "administered_at"]).flatMap { EntityCardProjection.parseDate($0, calendar: .current) },
                value(["hospital", "merchant", "provider"]), value(["doctor"]))
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_Hans"))
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }
    private static func hospitalScore(_ a: String, _ b: String) -> Int {
        let a = normalize(a), b = normalize(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 10 }
        let short = a.count <= b.count ? a : b, long = a.count <= b.count ? b : a
        // 弱相似仅作可更改预选；不删除“医院”等词去匹配所有机构。
        return short.count >= 4 && long.contains(short) && Double(short.count) / Double(long.count) >= 0.6 ? 6 : 0
    }
}
