import Foundation

/// 关系动作（2026-11-06 三轮评审结论）：关系不是第二套事实，只有“接受后状态会改变”
/// 的动作才值得出候选。已接受关系仍由现有 FK + `ocr_card_commit` 表达；本类型只服务
/// 读投影/建议的身份与去重，不写任何边表。
public enum CardAction: String, Sendable, CaseIterable, Codable {
    case fixAttribution
    case addFollowUp
    case reconcileMedication
    case openTrend
    case attachOrphan
    case mergeEncounter
    case dedupeRecord
    case attachDocument
}

/// 稳定建议身份：`patient · action · source · target · targetEvidence · evidence`。
///
/// - Domain 只产出明文串；Infrastructure 才 SHA256（Linux 无 CryptoKit）。
/// - 不含 `MatchedCard.id`（每次匹配随机）；来源用文档 sha + 页 + 行锚点，
///   或已确认事实的 `table:id`。
/// - 目标证据纳入 key：目标日期/医院/kind/名称变化 → 新 key，旧拒绝记忆不复活。
public struct CardActionKey: Sendable, Hashable, Codable {
    public let canonical: String

    public init(patientId: UUID, action: CardAction,
                source: String, target: String,
                targetEvidence: String, evidence: String) {
        self.canonical = [
            patientId.uuidString.lowercased(),
            action.rawValue,
            source,
            target,
            targetEvidence,
            evidence,
        ].joined(separator: "\u{1F}")
    }

    /// 证据集合的无序稳定摘要（排序后 `key=value`，换行分隔）。
    public static func evidenceDigest(_ evidence: [String: String]) -> String {
        evidence.keys.sorted().map { "\($0)=\(evidence[$0] ?? "")" }.joined(separator: "\n")
    }
}

/// 孤儿归属候选（Domain 纯值；不依赖 Infrastructure 行类型）。
public struct OrphanCard: Sendable, Equatable {
    public let patientId: UUID
    public let kind: String
    public let documentTypeKey: String?
    public let entityId: UUID?
    public let documentSha256: String?
    public let pageIndex: Int?
    public let rowAnchor: String?
    public let date: Date?
    public let hospital: String?
    public let department: String?
    public let doctor: String?
    public let currentEncounterId: UUID?

    public init(patientId: UUID, kind: String, documentTypeKey: String? = nil,
                entityId: UUID?, documentSha256: String? = nil, pageIndex: Int? = nil,
                rowAnchor: String? = nil, date: Date?, hospital: String?,
                department: String? = nil, doctor: String? = nil,
                currentEncounterId: UUID?) {
        self.patientId = patientId
        self.kind = kind
        self.documentTypeKey = documentTypeKey
        self.entityId = entityId
        self.documentSha256 = documentSha256
        self.pageIndex = pageIndex
        self.rowAnchor = rowAnchor
        self.date = date
        self.hospital = hospital
        self.department = department
        self.doctor = doctor
        self.currentEncounterId = currentEncounterId
    }
}

/// 就诊候选快照（由 Infrastructure 查询后传入；Domain 不读库）。
public struct EncounterCandidate: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let patientId: UUID
    public let date: Date
    public let kind: String
    public let hospital: String?
    public let department: String?
    public let doctor: String?
    /// 住院/日间手术的闭区间；非住院为 nil。
    public let stayStart: Date?
    public let stayEnd: Date?

    public init(id: UUID, patientId: UUID, date: Date, kind: String,
                hospital: String?, department: String? = nil, doctor: String? = nil,
                stayStart: Date? = nil, stayEnd: Date? = nil) {
        self.id = id
        self.patientId = patientId
        self.date = date
        self.kind = kind
        self.hospital = hospital
        self.department = department
        self.doctor = doctor
        self.stayStart = stayStart
        self.stayEnd = stayEnd
    }
}

public struct AttributionSuggestion: Sendable, Equatable, Identifiable {
    public let orphan: OrphanCard
    public let encounterId: UUID
    public let evidence: [String: String]
    public let key: CardActionKey
    public var id: String { key.canonical }

    public init(orphan: OrphanCard, encounterId: UUID,
                evidence: [String: String], key: CardActionKey) {
        self.orphan = orphan
        self.encounterId = encounterId
        self.evidence = evidence
        self.key = key
    }
}

/// 孤儿归属规划：批量、逐项、fail-closed。只在有“挂到哪次就诊”的两种可执行结果时
/// 产出候选；同父卡之间的 sameVisit 不产生候选（FK 已表达）。
public enum AttributionPlanner {
    /// 保存时预选可用 ±3；批量改挂必须更严：默认只接受同日/±1 日 + 医院精确。
    public static let defaultWindowDays = 1

    private static let genericHospitals: Set<String> = [
        "人民医院", "中医院", "中心医院", "妇幼保健院", "卫生院", "社区医院", "医院",
    ]
    public static func plan(patientId: UUID, orphans: [OrphanCard],
                            encounters: [EncounterCandidate], now: Date = Date(),
                            windowDays: Int = defaultWindowDays,
                            calendar: Calendar = .current) -> [AttributionSuggestion] {
        orphans.compactMap { orphan in
            suggest(orphan, patientId: patientId, encounters: encounters,
                    now: now, windowDays: windowDays, calendar: calendar)
        }
    }

    private static func suggest(_ orphan: OrphanCard, patientId: UUID,
                                encounters: [EncounterCandidate], now: Date,
                                windowDays: Int, calendar: Calendar) -> AttributionSuggestion? {
        guard orphan.patientId == patientId,
              orphan.entityId != nil,
              orphan.currentEncounterId == nil,
              orphan.documentTypeKey != DocumentTypeKey.checkupReport.rawValue,
              let date = orphan.date,
              let hospital = orphan.hospital,
              !normalize(hospital).isEmpty else { return nil }

        var scored: [(EncounterCandidate, Int, [String: String])] = []
        for candidate in encounters {
            guard candidate.patientId == patientId,
                  let candidateHospital = candidate.hospital,
                  let score = matchScore(orphan, date: date, hospital: hospital,
                                         candidate: candidate, candidateHospital: candidateHospital,
                                         now: now, windowDays: windowDays, calendar: calendar)
            else { continue }
            scored.append((candidate, score, evidence(orphan, candidate, date: date)))
        }
        guard let best = scored.map(\.1).max() else { return nil }
        let winners = scored.filter { $0.1 == best }
        guard winners.count == 1, let target = winners.first else { return nil }

        let source = orphan.documentSha256.map {
            "doc:\($0):\(orphan.pageIndex ?? 0):\(orphan.rowAnchor ?? "")"
        } ?? "entity:\(orphan.entityId?.uuidString.lowercased() ?? "nil")"
        let targetEvidence = [
            target.0.kind,
            target.0.hospital.map(normalize) ?? "",
            target.0.date.timeIntervalSince1970.description,
            target.0.stayStart?.timeIntervalSince1970.description ?? "",
            target.0.stayEnd?.timeIntervalSince1970.description ?? "",
        ].joined(separator: "|")
        let key = CardActionKey(
            patientId: patientId,
            action: .fixAttribution,
            source: source,
            target: "encounter:\(target.0.id.uuidString.lowercased())",
            targetEvidence: targetEvidence,
            evidence: CardActionKey.evidenceDigest(target.2))
        return AttributionSuggestion(orphan: orphan, encounterId: target.0.id,
                                    evidence: target.2, key: key)
    }

    private static func matchScore(_ orphan: OrphanCard, date: Date, hospital: String,
                                   candidate: EncounterCandidate, candidateHospital: String,
                                   now: Date, windowDays: Int, calendar: Calendar) -> Int? {
        guard candidate.kind != EncounterKind.checkup.rawValue,
              candidate.kind != EncounterKind.telemedicine.rawValue else { return nil }
        let hScore = hospitalScore(hospital, candidateHospital)
        guard hScore > 0 else { return nil }

        let dayDelta: Int
        if candidate.kind == EncounterKind.inpatient.rawValue
            || candidate.kind == EncounterKind.daySurgery.rawValue {
            let start = candidate.stayStart ?? candidate.date
            let end = candidate.stayEnd ?? now
            guard date >= start, date <= end else { return nil }
            dayDelta = 0
        } else {
            guard let days = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: date),
                to: calendar.startOfDay(for: candidate.date)).day else { return nil }
            guard abs(days) <= max(0, windowDays) else { return nil }
            dayDelta = abs(days)
        }

        let deptMatch = matches(orphan.department, candidate.department)
        let doctorMatch = matches(orphan.doctor, candidate.doctor)
        let generic = isGeneric(hospital) || isGeneric(candidateHospital)
        if generic && !(deptMatch && doctorMatch) { return nil }
        if let a = nonEmpty(orphan.department), let b = nonEmpty(candidate.department),
           normalize(a) != normalize(b) { return nil }
        guard hScore >= 10 else { return nil }

        return hScore + (doctorMatch ? 3 : 0) + (deptMatch ? 2 : 0) - dayDelta
    }

    private static func evidence(_ orphan: OrphanCard, _ candidate: EncounterCandidate,
                                 date: Date) -> [String: String] {
        var out = [
            "date": ISO8601DateFormatter().string(from: date),
            "kind": candidate.kind,
        ]
        if let hospital = candidate.hospital { out["hospital"] = hospital }
        if let department = candidate.department { out["department"] = department }
        if let doctor = candidate.doctor { out["doctor"] = doctor }
        return out
    }

    private static func matches(_ a: String?, _ b: String?) -> Bool {
        guard let a = nonEmpty(a), let b = nonEmpty(b) else { return false }
        return normalize(a) == normalize(b)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func isGeneric(_ hospital: String) -> Bool {
        genericHospitals.contains(normalize(hospital))
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "zh_Hans"))
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    /// 批量改挂只接受医院名精确相等（弱相似仅用于保存时预选，不用于批量归属）。
    private static func hospitalScore(_ a: String, _ b: String) -> Int {
        let a = normalize(a), b = normalize(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return a == b ? 10 : 0
    }
}
