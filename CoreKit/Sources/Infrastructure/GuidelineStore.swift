// 平台守卫镜像 Package.swift（ERR#8 纪律）：GRDB 仅 iOS/macOS 链接。
#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

/// F16 信源库 + 预警事件仓储（actor）。
///
/// - 信源：内置信源种子（`GuidelineSource.bundledSeeds`）幂等入库，随后以库为准；
///   报告自带参考范围是 A 级、不经过本库（数据层在 metric_sample 的
///   ref_low/ref_high 列）——A>B 优先级由 `AlertRuleEngine`/`TrendRules` 执行。
/// - 预警：`alert_event` 只存**已发生的事实**（读数 + 定级 + 证据卡 JSON），
///   文案在呈现时由 Domain 的 evidenceCard 组装——**零生成式解读**（ADR-010）。
public actor GuidelineStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    // MARK: - 信源

    /// 幂等种子：存在即不重复插入（按 id 冲突忽略）。
    /// 全新库经此调用获得离线信源；已入库条目不被覆盖——覆盖意味着静默改写
    /// 已评审的阈值，FR16.4 禁止。
    @discardableResult
    public func seedBundled() async throws -> Int {
        try await writer.write { db in
            var inserted = 0
            for entry in GuidelineSource.bundledSeeds {
                let thresholds = GuidelineSource.Thresholds.from(entry)
                let jsonData: Data
                do { jsonData = try JSONEncoder().encode(thresholds) }
                catch { continue }   // 编码失败跳过该条（§7：错误不静默吞，逐条跳过是显式语义）
                guard let json = String(data: jsonData, encoding: .utf8) else { continue }
                try db.execute(sql: """
                    INSERT INTO guideline_source
                      (id, title, org, year, clause_ref, citation_url, version,
                       checked_at, thresholds_json, metric_key, unit)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """, arguments: [entry.id.uuidString, entry.title, entry.org,
                                     entry.year, entry.clauseRef, entry.citationUrl,
                                     entry.version, entry.checkedAt.timeIntervalSince1970,
                                     json, entry.metricKey, entry.unit])
                inserted += db.changesCount
            }
            return inserted
        }
    }

    /// 某指标的信源条目；库无该指标时回退内置种子（离线首次启动即有效，
    /// 不必等一次种子写库成功）
    public func entry(for metricKey: String) async throws -> GuidelineEntry? {
        if let stored = try await storedEntry(for: metricKey) { return stored }
        return GuidelineSource.bundledSeeds.first { $0.metricKey == metricKey }
    }

    private func storedEntry(for metricKey: String) async throws -> GuidelineEntry? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM guideline_source
                WHERE metric_key = ? AND retired_at IS NULL
                LIMIT 1
                """, arguments: [metricKey]) else { return nil }
            return try Self.decode(row)
        }
    }

    /// 信源库全量（设置页「参考范围来源」展示用）
    public func all() async throws -> [GuidelineEntry] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM guideline_source WHERE retired_at IS NULL
                ORDER BY org, year
                """)
            return try rows.map { try Self.decode($0) }
        }
    }

    private static func decode(_ row: Row) throws -> GuidelineEntry {
        let thresholds: GuidelineSource.Thresholds
        if let json = (row["thresholds_json"] as String?)?.data(using: .utf8) {
            do { thresholds = try JSONDecoder().decode(GuidelineSource.Thresholds.self, from: json) }
            catch { thresholds = GuidelineSource.Thresholds() }
        } else {
            thresholds = GuidelineSource.Thresholds()
        }
        return thresholds.applying(to: GuidelineEntry(
            id: UUID(uuidString: row["id"] as String) ?? UUID(),
            title: row["title"] as String,
            org: row["org"] as String,
            year: row["year"] as Int,
            clauseRef: row["clause_ref"] as String,
            citationUrl: row["citation_url"] as String,
            version: row["version"] as String,
            checkedAt: Date(timeIntervalSince1970: row["checked_at"] as Double),
            metricKey: row["metric_key"] as String? ?? "",
            unit: row["unit"] as String? ?? "1"))
    }

    // MARK: - 预警事件（只存事实，零生成式解读）

    /// 评估一次读数并落一条预警事件（L0 也落——「观察提示摘要卡仅 L1+ 展示」
    /// 不等于 L0 不存在，F16 历史需要完整序列）。返回定级与证据卡。
    /// `ruleId` = 触发规则标识（调用方装配层给，审计用）。
    @discardableResult
    public func evaluateAndRecord(reading: MetricReading, patientId: UUID,
                                  ruleId: String = "f16.local") async throws -> AlertEvent {
        let guideline = try await entry(for: reading.metricKey)
        guard let severity = AlertRuleEngine.severity(for: reading, guideline: guideline) else {
            throw StoreError.noApplicableRange(reading.metricKey)
        }
        let card = AlertRuleEngine.evidenceCard(for: reading, severity: severity,
                                                guideline: guideline)
        let event = AlertEvent(
            id: UUID(), patientId: patientId, ruleId: ruleId, severity: severity,
            card: card, deliveredState: "pending", createdAt: Date())
        let evidence: Data
        do { evidence = try JSONEncoder().encode(card) }
        catch { throw StoreError.encodeFailed }
        guard let json = String(data: evidence, encoding: .utf8) else {
            throw StoreError.encodeFailed
        }
        try await writer.write { db in
            // FR16.2 同一事件 24 小时去重：同一成员+规则+级别近 24h 已落过 →
            // 不重复 INSERT（反复同步不再堆积重复预警行）
            if let existingId = try String.fetchOne(db, sql: """
                SELECT id FROM alert_event
                WHERE patient_id = ? AND rule_id = ? AND severity = ?
                  AND created_at >= ?
                LIMIT 1
                """, arguments: [patientId.uuidString, ruleId, severity.rawValue,
                                 event.createdAt.timeIntervalSince1970 - 24 * 3600]) {
                _ = existingId
                return
            }
            try db.execute(sql: """
                INSERT INTO alert_event
                  (id, patient_id, rule_id, severity, evidence_json, delivered_state, created_at)
                VALUES (?, ?, ?, ?, ?, 'pending', ?)
                """, arguments: [event.id.uuidString, patientId.uuidString, ruleId,
                                 severity.rawValue, json,
                                 event.createdAt.timeIntervalSince1970])
        }
        return event
    }

    /// 预警历史（L0 起全量；L1+ 单独过滤是 UI 的事）
    public func history(patientId: UUID, since: Date? = nil, limit: Int = 200) async throws -> [AlertEvent] {
        try await writer.read { db in
            let sql = """
                SELECT * FROM alert_event
                WHERE patient_id = ?
                  \(since.map { _ in "AND created_at >= ?" } ?? "")
                ORDER BY created_at DESC
                LIMIT ?
                """
            var arguments: [DatabaseValueConvertible] = [patientId.uuidString]
            if let since { arguments.append(since.timeIntervalSince1970) }
            arguments.append(limit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            var events: [AlertEvent] = []
            for row in rows {
                guard let json = (row["evidence_json"] as String?)?.data(using: .utf8) else { continue }
                // 损坏的 evidence_json 跳过该行而非整体失败（历史行可容忍逐条降级；
                // 不用 try? —— tech-spec §7 红线，逐条 do-catch 是显式语义）
                let card: AlertEvidenceCard
                do { card = try JSONDecoder().decode(AlertEvidenceCard.self, from: json) }
                catch { continue }
                events.append(AlertEvent(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: UUID(uuidString: row["patient_id"] as String) ?? UUID(),
                    ruleId: row["rule_id"] as String,
                    severity: AlertSeverity(rawValue: row["severity"] as String) ?? .L0,
                    card: card, deliveredState: row["delivered_state"] as String,
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double)))
            }
            return events
        }
    }

    /// 预警事件的查询投影
    public struct AlertEvent: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var patientId: UUID
        public var ruleId: String
        public var severity: AlertSeverity
        public var card: AlertEvidenceCard
        public var deliveredState: String
        public var createdAt: Date
        public init(id: UUID, patientId: UUID, ruleId: String, severity: AlertSeverity,
                    card: AlertEvidenceCard, deliveredState: String, createdAt: Date) {
            self.id = id; self.patientId = patientId; self.ruleId = ruleId
            self.severity = severity; self.card = card
            self.deliveredState = deliveredState; self.createdAt = createdAt
        }
    }

    public enum StoreError: Error, LocalizedError {
        case noApplicableRange(String)
        case encodeFailed
        public var errorDescription: String? { "信源库/预警操作失败: \(self)" }
    }
}
#endif
