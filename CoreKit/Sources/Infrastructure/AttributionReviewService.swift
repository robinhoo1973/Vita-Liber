#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain

/// 孤儿归属动作面（2026-11-06）：读 `AttributionQueryStore` 候选，用户确认后
/// 调既有 `OCRCardStore.associate` 写 FK，拒绝写 `notification_state`。
/// 不建关系表、不自动写；来源必须是已确认孤儿卡。
public actor AttributionReviewService {
    private let writer: any DatabaseWriter
    private let query: AttributionQueryStore

    public init(writer: any DatabaseWriter) {
        self.writer = writer
        self.query = AttributionQueryStore(writer: writer)
    }

    public func suggestions(patientId: UUID, now: Date = Date(),
                            calendar: Calendar = .current) async throws -> [AttributionSuggestion] {
        let all = try await query.suggestions(patientId: patientId, now: now, calendar: calendar)
        guard !all.isEmpty else { return [] }
        let dismissed = try await dismissedKeys(all, patientId: patientId)
        return all.filter { !dismissed.contains(Self.dismissKey($0, patientId: patientId)) }
    }

    /// 只对已确认孤儿执行；kind metric_sample = 检验表头，写 lab_report.encounter_id。
    public func link(_ suggestion: AttributionSuggestion) async throws {
        guard let entityId = suggestion.orphan.entityId else { return }
        let kind = Self.detailKind(for: suggestion.orphan.kind)
        try await OCRCardStore(writer: writer).associate(
            kind: kind, entityId: entityId,
            patientId: suggestion.orphan.patientId,
            encounterId: suggestion.encounterId)
    }

    public func dismiss(_ suggestion: AttributionSuggestion) async throws {
        let key = Self.dismissKey(suggestion, patientId: suggestion.orphan.patientId)
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO notification_state (item_key, kind, read_at, archived_at)
                VALUES (?, 'card_relation', ?, ?)
                ON CONFLICT(item_key) DO UPDATE SET archived_at = excluded.archived_at
                """, arguments: [key, Date().timeIntervalSince1970, Date().timeIntervalSince1970])
        }
    }

    private func dismissedKeys(_ suggestions: [AttributionSuggestion], patientId: UUID) async throws -> Set<String> {
        let keys = suggestions.map { Self.dismissKey($0, patientId: patientId) }
        guard !keys.isEmpty else { return [] }
        return try await writer.read { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT item_key FROM notification_state
                WHERE kind = 'card_relation' AND item_key IN (\(keys.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(keys))
            return Set(rows)
        }
    }

    private static func dismissKey(_ suggestion: AttributionSuggestion, patientId: UUID) -> String {
        "relation-" + CryptoKitContentHasher().sha256Hex(
            Data("\(patientId.uuidString.lowercased())|\(suggestion.key.canonical)".utf8))
    }

    private static func detailKind(for orphanKind: String) -> String {
        orphanKind == "metric_sample" ? "lab_report" : orphanKind
    }
}
#endif
