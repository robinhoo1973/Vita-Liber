#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F5 资料库数据仓（SP-09）：列表/归档/收藏/去重/入库。
/// BR-002：原件永不覆盖——写路径只 INSERT 新行或软状态变更，绝不 UPDATE 原件列。
public actor DocumentStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public struct DocumentRow: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var patientId: UUID
        public var encounterId: UUID?
        public var docType: String
        public var sha256: String?
        public var mimeType: String?
        public var origin: String
        public var status: String          // active/favorite/archived
        public var isSensitive: Bool
        public var title: String?
        /// 来源徽章 A–E（BR-003）：机器识别未确认 = 'D'，用户确认升 'C'。
        public var grade: String
        public var createdAt: Date
        public init(id: UUID, patientId: UUID, encounterId: UUID?, docType: String,
                    sha256: String?, mimeType: String?, origin: String, status: String,
                    isSensitive: Bool, title: String?, grade: String = "C", createdAt: Date) {
            self.id = id; self.patientId = patientId; self.encounterId = encounterId
            self.docType = docType; self.sha256 = sha256; self.mimeType = mimeType
            self.origin = origin; self.status = status; self.isSensitive = isSensitive
            self.title = title; self.grade = grade; self.createdAt = createdAt
        }
    }

    public func list(patientId: UUID, includeArchived: Bool = false,
                     limit: Int = 200) async throws -> [DocumentRow] {
        try await writer.read { db in
            let statusClause = includeArchived ? "" : "AND status != 'archived'"
            return try Row.fetchAll(db, sql: """
                SELECT * FROM document_file
                WHERE patient_id = ? \(statusClause)
                ORDER BY created_at DESC LIMIT ?
                """, arguments: [patientId.uuidString, limit]).map(Self.row)
        }
    }

    /// FR5.8 归档/取消归档（归档资料默认不出现在列表与搜索）
    public func setArchived(id: UUID, archived: Bool, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE document_file SET status = ?, updated_at = ? WHERE id = ?
                """, arguments: [archived ? "archived" : "active",
                                 now.timeIntervalSince1970, id.uuidString])
        }
    }

    /// FR5.8 收藏
    public func setFavorite(id: UUID, favorite: Bool, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE document_file SET status = ?, updated_at = ? WHERE id = ?
                """, arguments: [favorite ? "favorite" : "active",
                                 now.timeIntervalSince1970, id.uuidString])
        }
    }

    /// FR5.6 重复检测：文件哈希精确重复（感知哈希在 CaptureQuality DuplicateDetectionService）。
    /// 绝不自动删除——只提示并给并排对比（UI 层）。
    public func duplicates(sha256: String, patientId: UUID) async throws -> [DocumentRow] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM document_file WHERE patient_id = ? AND sha256 = ?
                """, arguments: [patientId.uuidString, sha256]).map(Self.row)
        }
    }

    /// 入库（BR-002：INSERT 新行；meta_json 承载投影元数据）。
    /// ocrText 写入 FTS 检索列（触发器自动索引）；grade = 来源徽章（BR-003：
    /// 机器识别未确认传 'D'，手工/已确认传 'C'）。
    @discardableResult
    public func save(patientId: UUID, docType: String, sha256: String?,
                     mimeType: String?, origin: String, isSensitive: Bool,
                     metaJSON: String?, title: String?,
                     ocrText: String? = nil, grade: String = "C",
                     now: Date = Date()) async throws -> UUID {
        let id = UUID()
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO document_file
                  (id, patient_id, doc_type, sha256, mime_type, origin, status,
                   is_sensitive, meta_json, title, ocr_text, grade, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString, docType, sha256,
                                 mimeType, origin, isSensitive ? 1 : 0,
                                 metaJSON, title, ocrText, grade,
                                 now.timeIntervalSince1970,
                                 now.timeIntervalSince1970])
        }
        return id
    }

    /// BR-003 D→C 闸门：用户显式确认机器识别文本后，文档才进入检索与 AI 事实链。
    public func confirmText(id: UUID, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE document_file SET grade = 'C', updated_at = ? WHERE id = ? AND grade = 'D'
                """, arguments: [now.timeIntervalSince1970, id.uuidString])
        }
    }

    private static func row(_ row: GRDB.Row) -> DocumentStore.DocumentRow {
        DocumentRow(id: UUID(uuidString: row["id"] as String) ?? UUID(),
            patientId: UUID(uuidString: row["patient_id"] as String) ?? UUID(),
            encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
            docType: row["doc_type"] as String,
            sha256: row["sha256"] as String?,
            mimeType: row["mime_type"] as String?,
            origin: row["origin"] as String,
            status: row["status"] as String,
            isSensitive: (row["is_sensitive"] as Int?) == 1,
            title: row["title"] as String?,
            grade: (row["grade"] as String?) ?? "C",
            createdAt: Date(timeIntervalSince1970: row["created_at"] as Double))
    }
}
#endif
