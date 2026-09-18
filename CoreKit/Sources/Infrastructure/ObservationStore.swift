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
            // 单实例解码器复用（与 OCRCardStore.refreshDocumentProjection 同纪律）：
            // 逐行新建 JSONDecoder 会每行重建类型元数据，列表 ≤100 行时是纯浪费。
            let decoder = JSONDecoder()
            return try Row.fetchAll(db, sql: """
                SELECT * FROM observation
                WHERE patient_id = ? ORDER BY occurred_at DESC LIMIT ?
                """, arguments: [patientId.uuidString, limit]).map { row in
                Self.rowToEvent(row, memberId: patientId, decoder: decoder)
            }
        }
    }

    /// FR8.11 观察详情页单行投影（与 list 同映射——详情页与列表字段不得分叉）。
    public func fetch(id: UUID) async throws -> ObservationEvent? {
        let row = try await writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM observation WHERE id = ?",
                             arguments: [id.uuidString])
        }
        guard let row else { return nil }
        return Self.rowToEvent(row, memberId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)) ?? UUID(),
                               decoder: JSONDecoder())
    }

    /// FR8.8 删除观察记录：硬删行（明示三问后执行——原图经孤儿对账清除，
    /// 备份中的处理版本不受影响；医生摘要已生成内容保留）。
    public func delete(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM observation WHERE id = ?", arguments: [id.uuidString])
            guard db.changesCount > 0 else { throw DeleteError.missingRow }
        }
    }

    public enum DeleteError: Error { case missingRow }

    /// FR8.7 事后补字段（详情页行内编辑写回）：只更新提交的列 + updated_at。
    public func updateExtended(id: UUID, bodyPart: String? = nil, durationMin: Int? = nil,
                               frequency: String? = nil, isFirst: Bool? = nil,
                               trigger: String? = nil, accompanying: String? = nil,
                               painScore: Int? = nil, medsDiet: String? = nil,
                               consultedDoctor: Bool? = nil, description: String? = nil,
                               now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE observation SET body_part = COALESCE(?, body_part),
                  duration_min = COALESCE(?, duration_min), frequency = COALESCE(?, frequency),
                  is_first = COALESCE(?, is_first), trigger = COALESCE(?, trigger),
                  accompanying = COALESCE(?, accompanying), pain_score = COALESCE(?, pain_score),
                  meds_diet = COALESCE(?, meds_diet), consulted_doctor = COALESCE(?, consulted_doctor),
                  description = COALESCE(?, description), updated_at = ?
                WHERE id = ?
                """, arguments: [bodyPart, durationMin, frequency,
                                 isFirst.map { $0 ? 1 : 0 }, trigger, accompanying, painScore,
                                 medsDiet, consultedDoctor.map { $0 ? 1 : 0 }, description,
                                 now.timeIntervalSince1970, id.uuidString])
        }
    }

    /// 行 → 事件（V3.65 全字段投影的唯一出口：list/fetch 共用，
    /// 新列上线只改这一处）。
    private static func rowToEvent(_ row: Row, memberId: UUID, decoder: JSONDecoder) -> ObservationEvent {
        ObservationEvent(
            id: UUID(uuidString: row["id"] as String) ?? UUID(),
            groupId: (row["group_id"] as String?).flatMap(UUID.init(uuidString:)),
            kind: ObservationKind(rawValue: row["kind"] as String) ?? .custom,
            occurredAt: Date(timeIntervalSince1970: row["occurred_at"] as Double),
            capturedAt: (row["captured_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            description: row["description"] as String?,
            selfMark: row["self_mark"] as String?,
            memberId: memberId,
            mediaAssetIds: decodeMediaIds(row["media_asset_ids"] as String?, decoder: decoder),
            bodyPart: row["body_part"] as String?,
            durationMin: row["duration_min"] as Int?,
            frequency: row["frequency"] as String?,
            isFirst: (row["is_first"] as Int?).map { $0 != 0 },
            trigger: row["trigger"] as String?,
            accompanying: row["accompanying"] as String?,
            painScore: row["pain_score"] as Int?,
            medsDiet: row["meds_diet"] as String?,
            consultedDoctor: (row["consulted_doctor"] as Int? ?? 0) != 0,
            encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
            healthProblemId: (row["health_problem_id"] as String?).flatMap(UUID.init(uuidString:)))
    }

    /// 媒体 id 列是 JSON 数组；单条损坏降级为空数组，不拖垮整个列表（§7 显式降级）。
    private static func decodeMediaIds(_ json: String?, decoder: JSONDecoder) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        do { return try decoder.decode([String].self, from: data) }
        catch { return [] }
    }

    /// 全库被引用资产 id 集（启动孤儿对账用）：observation.media_asset_ids +
    /// patient_profile.avatar_asset_id + stock_lot.storage_photo_id/box_photo_id。
    /// 审查修复：原实现只汇总观察媒体——成员头像与库存照片（均 REFERENCES asset）
    /// 会被孤儿对账当垃圾永久删除，BR-002 原件不可逆丢失
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
            let avatarIds = try String.fetchAll(db, sql: """
                SELECT avatar_asset_id FROM patient_profile WHERE avatar_asset_id IS NOT NULL
                """)
            ids.formUnion(avatarIds)
            let stockPhotoIds = try String.fetchAll(db, sql: """
                SELECT storage_photo_id FROM stock_lot WHERE storage_photo_id IS NOT NULL
                UNION SELECT box_photo_id FROM stock_lot WHERE box_photo_id IS NOT NULL
                """)
            ids.formUnion(stockPhotoIds)
            return ids
        }
    }
}

/// F23 过敏记录数据仓（ADR-018 一等事件）
public actor AllergyStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// 全仓审查 2026-09-18（F-A4-01，P0）：`occurredAt` 此前恒写保存时刻、表单「发生时间」
    /// 与「过敏原类型」被静默丢弃。现两者独立入参：`occurredAt` 默认 = now（兼容既有调用），
    /// `allergenKind` 可空（FR23.1 三档词汇 `SevereReactionRules.allergenKinds`，落库原值）。
    public func create(id: UUID = UUID(), patientId: UUID, substance: String,
                       severity: String, reactionTags: [String], note: String?,
                       allergenKind: String? = nil, occurredAt: Date? = nil,
                       now: Date = Date()) async throws {
        // 审查修复：展示词（轻/中/重）→ 规范值（mild/moderate/severe）——
        // DDL CHECK 只接受英文枚举，原样 INSERT 违反约束、每次保存静默失败
        let canonical = SevereReactionRules.canonicalSeverity(severity)
        let occurred = occurredAt ?? now
        try await writer.write { db in
            let tags = String(data: try JSONEncoder().encode(reactionTags), encoding: .utf8) ?? "[]"
            try db.execute(sql: """
                INSERT INTO allergy_event
                  (id, patient_id, substance, reaction_tags, severity, occurred_at, note,
                   allergen_kind, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString, substance, tags, canonical,
                                 occurred.timeIntervalSince1970, note, allergenKind,
                                 now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
    }

    public struct AllergyRow: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var substance: String
        public var severity: String
        public var occurredAt: Date
        /// v30：过敏原类型（药品/食物/其他）；历史行 nil = 未登记
        public var allergenKind: String?
        public init(id: UUID, substance: String, severity: String, occurredAt: Date,
                    allergenKind: String? = nil) {
            self.id = id; self.substance = substance; self.severity = severity; self.occurredAt = occurredAt
            self.allergenKind = allergenKind
        }
    }

    public func list(patientId: UUID) async throws -> [AllergyRow] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, substance, severity, occurred_at, allergen_kind FROM allergy_event
                WHERE patient_id = ? ORDER BY occurred_at DESC
                """, arguments: [patientId.uuidString]).map { row in
                AllergyRow(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                           substance: row["substance"] as String,
                           severity: row["severity"] as String,
                           occurredAt: Date(timeIntervalSince1970: (row["occurred_at"] as Double?) ?? 0),
                           allergenKind: row["allergen_kind"] as String?)
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
                """, arguments: [substance, SevereReactionRules.canonicalSeverity(severity),
                                 note, now.timeIntervalSince1970, id.uuidString])
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
