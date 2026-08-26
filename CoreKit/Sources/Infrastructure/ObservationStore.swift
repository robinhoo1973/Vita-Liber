#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F8 观察数据仓（actor，GRDB）：创建/聚合查询。
/// 敏感保护链（BR-007/008）语义在 App 层实施——存储层只存 media_asset_ids 引用。
public actor ObservationStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public func create(id: UUID = UUID(), patientId: UUID, kind: String, description: String,
                       selfMark: String?, groupId: UUID? = nil, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO observation
                  (id, patient_id, kind, occurred_at, description, group_id, self_mark, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString, kind,
                                 now.timeIntervalSince1970, description,
                                 groupId?.uuidString, selfMark,
                                 now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
    }

    public func list(patientId: UUID, limit: Int = 100) async throws -> [ObservationEvent] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, group_id, kind, occurred_at, description, self_mark FROM observation
                WHERE patient_id = ? ORDER BY occurred_at DESC LIMIT ?
                """, arguments: [patientId.uuidString, limit]).map { row in
                ObservationEvent(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    groupId: (row["group_id"] as String?).flatMap(UUID.init(uuidString:)),
                    kind: row["kind"] as String,
                    occurredAt: Date(timeIntervalSince1970: row["occurred_at"] as Double),
                    description: row["description"] as String?,
                    selfMark: row["self_mark"] as String?,
                    memberId: patientId)
            }
        }
    }
}

/// F23 过敏记录数据仓（ADR-018 一等事件）
public actor AllergyStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public func create(id: UUID = UUID(), patientId: UUID, substance: String,
                       severity: String, reactionTags: [String], note: String?,
                       now: Date = Date()) async throws {
        try await writer.write { db in
            let tags = String(data: try JSONEncoder().encode(reactionTags), encoding: .utf8) ?? "[]"
            try db.execute(sql: """
                INSERT INTO allergy_event
                  (id, patient_id, substance, reaction_tags, severity, occurred_at, note, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString, substance, tags, severity,
                                 now.timeIntervalSince1970, note,
                                 now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
    }

    public struct AllergyRow: Sendable, Equatable {
        public var id: UUID
        public var substance: String
        public var severity: String
        public var occurredAt: Date
        public init(id: UUID, substance: String, severity: String, occurredAt: Date) {
            self.id = id; self.substance = substance; self.severity = severity; self.occurredAt = occurredAt
        }
    }

    public func list(patientId: UUID) async throws -> [AllergyRow] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, substance, severity, occurred_at FROM allergy_event
                WHERE patient_id = ? ORDER BY occurred_at DESC
                """, arguments: [patientId.uuidString]).map { row in
                AllergyRow(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                           substance: row["substance"] as String,
                           severity: row["severity"] as String,
                           occurredAt: Date(timeIntervalSince1970: (row["occurred_at"] as Double?) ?? 0))
            }
        }
    }
}
#endif
