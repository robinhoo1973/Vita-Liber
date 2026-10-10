#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain

/// Historical evaluations and qualified reminders have distinct read contracts.
public actor GuidelineStore {
    private let writer: any DatabaseWriter
    public init(writer: any DatabaseWriter) { self.writer = writer }

    @discardableResult
    public func seedBundled() async throws -> Int {
        try await writer.write { db in
            var inserted = 0
            for entry in GuidelineSource.bundledSeeds {
                let json = String(decoding: try JSONEncoder().encode(GuidelineSource.Thresholds.from(entry)), as: UTF8.self)
                try db.execute(sql: """
                    INSERT INTO guideline_source
                      (id, title, org, year, clause_ref, citation_url, version, checked_at, thresholds_json, metric_key, unit)
                    SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE NOT EXISTS (
                      SELECT 1 FROM guideline_source WHERE metric_key = ? AND version = ?
                        AND org = ? AND clause_ref = ?)
                    ON CONFLICT(id) DO NOTHING
                    """, arguments: [entry.id.uuidString, entry.title, entry.org, entry.year, entry.clauseRef,
                        entry.citationUrl, entry.version, entry.checkedAt.timeIntervalSince1970, json, entry.metricKey,
                        entry.unit, entry.metricKey, entry.version, entry.org, entry.clauseRef])
                inserted += db.changesCount
            }
            return inserted
        }
    }

    public func entry(for metricKey: String) async throws -> GuidelineEntry? {
        try await writer.read { db in try Self.entry(for: metricKey, db: db) }
    }

    private static func entry(for key: String, db: Database) throws -> GuidelineEntry? {
        if let row = try Row.fetchOne(db, sql: """
            SELECT * FROM guideline_source WHERE metric_key = ? AND retired_at IS NULL
            ORDER BY checked_at DESC, rowid ASC LIMIT 1
            """, arguments: [key]) { return try decode(row) }
        return GuidelineSource.bundledSeeds.first { $0.metricKey == key }
    }

    public func all() async throws -> [GuidelineEntry] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM guideline_source WHERE retired_at IS NULL ORDER BY org, year, rowid")
            var seen = Set<String>()
            return try rows.map(Self.decode).filter {
                seen.insert([$0.metricKey, $0.version, $0.org, $0.clauseRef].joined(separator: "|")).inserted
            }
        }
    }

    private static func decode(_ row: Row) throws -> GuidelineEntry {
        let thresholds: GuidelineSource.Thresholds
        if let json = (row["thresholds_json"] as String?)?.data(using: .utf8) {
            thresholds = try JSONDecoder().decode(GuidelineSource.Thresholds.self, from: json)
        } else { thresholds = GuidelineSource.Thresholds() }
        guard let id = UUID(uuidString: row["id"] as String) else { throw StoreError.encodeFailed }
        return thresholds.applying(to: GuidelineEntry(id: id, title: row["title"], org: row["org"], year: row["year"],
            clauseRef: row["clause_ref"], citationUrl: row["citation_url"], version: row["version"],
            checkedAt: Date(timeIntervalSince1970: row["checked_at"]),
            metricKey: row["metric_key"] as String? ?? "", unit: row["unit"] as String? ?? "1"))
    }

    /// Kept for local evaluation/history consumers. A single reading never proves sustained eligibility.
    @discardableResult
    public func evaluateAndRecord(reading: MetricReading, patientId: UUID,
                                  ruleId: String = "f16.local") async throws -> AlertEvent {
        try await writer.write { db in
            let guideline = try Self.entry(for: reading.metricKey, db: db)
            guard let severity = AlertRuleEngine.severity(for: reading, guideline: guideline) else {
                throw StoreError.noApplicableRange(reading.metricKey)
            }
            let card = AlertRuleEngine.evidenceCard(for: reading, severity: severity, guideline: guideline)
            return try Self.save(card: card, patientId: patientId, ruleId: ruleId, qualified: false, db: db)
        }
    }

    /// 收口批E②（第九轮审查，FR16.2 履约口径）：「连续 3 次读数越限 → 至少 L1」
    /// 此前只对设备批量轨生效（recordQualifiedHealthReadings）；手录/自测读数
    /// 永不参与分级（告警引擎对用户主动录入的读数静默）。本方法在**手录落库后**
    /// 读取该指标最近 `consecutiveThreshold` 条（含本条）走同一 Domain 出口
    /// `AlertRuleEngine.escalate`——窗口内全部定级且全部越限才升 L1+；合格即建
    /// alert_event（qualified=true，24h 去重由 save 的 episode 键承担，与设备轨同源）。
    /// 返回新建事件（未达标/未越限/阈值待医学审校 → nil）。
    @discardableResult
    public func evaluateRecentManualReadings(patientId: UUID, metricKey: String) async throws -> AlertEvent? {
        try await writer.write { db in
            guard !GuidelineSource.thresholdsAwaitMedicalReview else { return nil }
            let rows = try Row.fetchAll(db, sql: """
                SELECT metric_key, value, unit, measured_at, origin FROM metric_sample
                WHERE patient_id = ? AND metric_key = ? AND excluded = 0 AND value IS NOT NULL
                ORDER BY measured_at DESC LIMIT ?
                """, arguments: [patientId.uuidString, metricKey, AlertRuleEngine.consecutiveThreshold])
            let recent = rows.reversed().compactMap { row -> MetricReading? in
                guard let value = row["value"] as Double?,
                      let measuredAt = row["measured_at"] as Double? else { return nil }
                return MetricReading(metricKey: row["metric_key"] as String,
                                     value: value,
                                     unit: row["unit"] as String? ?? "",
                                     origin: MetricOrigin(rawValue: row["origin"] as String? ?? "manual") ?? .manual,
                                     measuredAt: Date(timeIntervalSince1970: measuredAt))
            }
            guard let guideline = try Self.entry(for: AlertRuleEngine.guidelineKey(for: metricKey), db: db) else { return nil }
            guard let severity = AlertRuleEngine.escalate(recent: recent, guideline: guideline) else { return nil }
            // 锚定读数 = 窗口内最近一次**越限**读数（证据卡呈现最差事实读数）
            guard let anchor = recent.last(where: { AlertRuleEngine.severity(for: $0, guideline: guideline) != nil }) else { return nil }
            let card = AlertRuleEngine.evidenceCard(for: anchor, severity: severity, guideline: guideline)
            return try Self.save(card: card, patientId: patientId, ruleId: "f16.manual", qualified: true, db: db)
        }
    }

    /// Called inside the metric/checkpoint transaction, never after its cursor has advanced.
    static func recordQualifiedHealthReadings(_ readings: [MetricReading], patientId: UUID, db: Database) throws -> Int {
        guard !GuidelineSource.thresholdsAwaitMedicalReview else { return 0 }
        var entries: [String: GuidelineEntry] = [:]
        for key in Set(readings.map(\.metricKey)) {
            // 判定键归一化单一事实源 = AlertRuleEngine.guidelineKey（Domain）；
            // 静息心率行键 restingHeartRate → AHA 种子键 heart_rate。此前内联
            // 映射在 Infrastructure，静默漏警即由此漂移（结构轮 2026-09-15）。
            entries[key] = try entry(for: AlertRuleEngine.guidelineKey(for: key), db: db)
        }
        let graded = readings.map {
            AlertRuleEngine.GradedReading(reading: $0, severity: AlertRuleEngine.severity(for: $0, guideline: entries[$0.metricKey]))
        }
        var count = 0
        for candidate in AlertRuleEngine.sustainedViolations(graded) {
            guard let severity = candidate.severity else { continue }
            var card = AlertRuleEngine.evidenceCard(for: candidate.reading, severity: severity,
                                                    guideline: entries[candidate.reading.metricKey])
            card.episodeStart = candidate.episodeStart
            _ = try save(card: card, patientId: patientId, ruleId: "f16.healthkit", qualified: true, db: db)
            count += db.changesCount
        }
        return count
    }

    private static func save(card: AlertEvidenceCard, patientId: UUID, ruleId: String,
                             qualified: Bool, db: Database) throws -> AlertEvent {
        let clockKey = card.episodeStart ?? card.measuredAt
        if let row = try Row.fetchOne(db, sql: """
            SELECT * FROM alert_event WHERE patient_id = ? AND rule_id = ? AND severity = ?
              AND json_extract(evidence_json, '$.metricKey') IS ?
              AND json_extract(evidence_json, '$.origin') IS ?
              AND json_extract(evidence_json, '$.sourceIdentifier') IS ?
              AND json_extract(evidence_json, '$.guidelineVersion') IS ?
              AND COALESCE(json_extract(evidence_json, '$.episodeStart'), json_extract(evidence_json, '$.measuredAt')) IS ?
            LIMIT 1
            """, arguments: [patientId.uuidString, ruleId, card.severity.rawValue, card.metricKey,
                card.origin, card.sourceIdentifier, card.guidelineVersion, clockKey?.timeIntervalSinceReferenceDate]) {
            // Return the persisted evidence, not a different card carrying its UUID.
            return try decodeEvent(row)
        }
        let id = UUID()
        let now = Date()
        let json = String(decoding: try JSONEncoder().encode(card), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO alert_event (id, patient_id, rule_id, severity, evidence_json, qualified, delivered_state, created_at)
            VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
            """, arguments: [id.uuidString, patientId.uuidString, ruleId, card.severity.rawValue, json,
                             qualified ? 1 : 0, now.timeIntervalSince1970])
        return AlertEvent(id: id, patientId: patientId, ruleId: ruleId, severity: card.severity,
                          card: card, deliveredState: "pending", createdAt: now, qualified: qualified)
    }

    public func history(patientId: UUID, since: Date? = nil, limit: Int = 200,
                        qualifiedOnly: Bool = false, pendingOnly: Bool = false,
                        activeOnly: Bool = false) async throws -> [AlertEvent] {
        try await writer.read { db in
            let sql = """
                SELECT * FROM alert_event WHERE patient_id = ?
                  \(since == nil ? "" : "AND created_at >= ?")
                  \(qualifiedOnly ? "AND qualified = 1 AND severity != 'L0'" : "")
                  \(pendingOnly ? "AND delivered_state IN ('pending','deferred')" : "")
                  \(activeOnly ? "AND NOT EXISTS (SELECT 1 FROM notification_state n WHERE n.item_key = 'alert-' || alert_event.id AND n.archived_at IS NOT NULL)" : "")
                ORDER BY created_at DESC, id LIMIT ?
                """
            var args: [DatabaseValueConvertible] = [patientId.uuidString]
            if let since { args.append(since.timeIntervalSince1970) }
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map(Self.decodeEvent)
        }
    }

    public func event(id: UUID, patientId: UUID) async throws -> AlertEvent? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM alert_event WHERE id = ? AND patient_id = ?",
                                            arguments: [id.uuidString, patientId.uuidString]) else { return nil }
            return try Self.decodeEvent(row)
        }
    }

    public func markScheduled(id: UUID, patientId: UUID, at: Date) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE alert_event SET delivered_state = 'scheduled', scheduled_at = ?
                WHERE id = ? AND patient_id = ? AND qualified = 1
                """, arguments: [at.timeIntervalSince1970, id.uuidString, patientId.uuidString])
        }
    }

    private static func decodeEvent(_ row: Row) throws -> AlertEvent {
        guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]),
              let severity = AlertSeverity(rawValue: row["severity"]) else { throw StoreError.encodeFailed }
        let card = try JSONDecoder().decode(AlertEvidenceCard.self, from: Data((row["evidence_json"] as String).utf8))
        return AlertEvent(id: id, patientId: patient, ruleId: row["rule_id"], severity: severity, card: card,
            deliveredState: row["delivered_state"], createdAt: Date(timeIntervalSince1970: row["created_at"]),
            qualified: (row["qualified"] as Int?) == 1)
    }

    public struct AlertEvent: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var patientId: UUID
        public var ruleId: String
        public var severity: AlertSeverity
        public var card: AlertEvidenceCard
        public var deliveredState: String
        public var createdAt: Date
        public var qualified: Bool
        public init(id: UUID, patientId: UUID, ruleId: String, severity: AlertSeverity,
                    card: AlertEvidenceCard, deliveredState: String, createdAt: Date, qualified: Bool = false) {
            self.id = id; self.patientId = patientId; self.ruleId = ruleId; self.severity = severity
            self.card = card; self.deliveredState = deliveredState; self.createdAt = createdAt; self.qualified = qualified
        }
    }

    public enum StoreError: Error, LocalizedError {
        case noApplicableRange(String), encodeFailed
        public var errorDescription: String? { "Guideline data could not be processed: \(self)" }
    }
}
#endif
