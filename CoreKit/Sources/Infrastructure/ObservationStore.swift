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

    public func create(id: UUID = UUID(), patientId: UUID, kind: ObservationKind, description: String,
                       selfMark: String?, groupId: UUID? = nil, mediaAssetIds: [String] = [],
                       now: Date = Date()) async throws {
        try await writer.write { db in
            let mediaJSON = mediaAssetIds.isEmpty ? nil
                : String(data: try JSONEncoder().encode(mediaAssetIds), encoding: .utf8)
            try db.execute(sql: """
                INSERT INTO observation
                  (id, patient_id, kind, occurred_at, description, group_id, self_mark,
                   media_asset_ids, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString, kind.rawValue,
                                 now.timeIntervalSince1970, description,
                                 groupId?.uuidString, selfMark,
                                 mediaJSON,
                                 now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
    }

    public func list(patientId: UUID, limit: Int = 100) async throws -> [ObservationEvent] {
        try await writer.read { db in
            let decoder = JSONDecoder()   // 行循环复用单例（每行 new 一个为纯浪费）
            return try Row.fetchAll(db, sql: """
                SELECT id, group_id, kind, occurred_at, description, self_mark, media_asset_ids
                FROM observation
                WHERE patient_id = ? ORDER BY occurred_at DESC LIMIT ?
                """, arguments: [patientId.uuidString, limit]).map { row in
                ObservationEvent(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    groupId: (row["group_id"] as String?).flatMap(UUID.init(uuidString:)),
                    // SQL 边界才动 rawValue；未知历史值回落 custom（既有行兼容）
                    kind: ObservationKind(rawValue: row["kind"] as String) ?? .custom,
                    occurredAt: Date(timeIntervalSince1970: row["occurred_at"] as Double),
                    description: row["description"] as String?,
                    selfMark: row["self_mark"] as String?,
                    memberId: patientId,
                    mediaAssetIds: Self.decodeMediaIds(row["media_asset_ids"] as String?,
                                                       decoder: decoder))
            }
        }
    }

    /// 媒体 id 列是 JSON 数组；单条损坏降级为空数组，不拖垮整个列表（§7 显式降级）。
    private static func decodeMediaIds(_ json: String?, decoder: JSONDecoder) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        do { return try decoder.decode([String].self, from: data) }
        catch { return [] }
    }

    /// 全库被引用资产 id 集（启动孤儿对账用）：跨成员汇总 observation.media_asset_ids。
    public func allReferencedAssetIds() async throws -> Set<String> {
        try await writer.read { db in
            let decoder = JSONDecoder()
            let rows = try Row.fetchAll(db, sql: """
                SELECT media_asset_ids FROM observation WHERE media_asset_ids IS NOT NULL
                """)
            var ids: Set<String> = []
            for row in rows {
                ids.formUnion(Self.decodeMediaIds(row["media_asset_ids"] as String?, decoder: decoder))
            }
            return ids
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

    public struct AllergyRow: Sendable, Equatable, Identifiable {
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

    /// FR23.6 修改（严重度/过敏原等；事件是自述事实，编辑留审计由调用方记）
    public func update(id: UUID, substance: String, severity: String,
                       note: String?, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE allergy_event SET substance = ?, severity = ?, note = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [substance, severity, note, now.timeIntervalSince1970, id.uuidString])
        }
    }

    /// FR23.6 删除（删除前明示影响——紧急卡/医生摘要联动，由 UI 提示）
    public func delete(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM allergy_event WHERE id = ?", arguments: [id.uuidString])
        }
    }
}
#endif
