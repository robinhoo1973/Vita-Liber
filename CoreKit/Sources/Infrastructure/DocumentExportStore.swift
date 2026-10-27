#if os(iOS) || os(macOS)
// linux-blind: GRDB（Apple 平台依赖）—— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Protocols

/// 导出副本账本（2026-10-27 存储边界委员会 D1 / schema v49）。
///
/// 语义：
/// - **事实源仍是 canonical 原件（media 根）与 `document_file`**；本账本只记录
///   Documents 用户面副本的映射（会话目录名、显示名、相对路径、漂移态）。
/// - 副本可被用户在 Files/文件 App 中改名/删除/移动——对账发现漂移只置
///   `missing/removed` tombstone，**绝不回删 canonical**（BR-002 原件不可变）。
/// - `document_file` 删除行级联删本行；会话删除只 SET NULL（副本保留，
///   目录名冻结，D5/E2）。
public actor DocumentExportStore {
    public struct Record: Sendable, Equatable, Identifiable {
        public var documentID: UUID
        public var conversationID: UUID?
        public var directoryName: String
        public var displayName: String
        /// 相对 Documents 基的路径（`<会话目录>/<文件名>`）。
        public var relativePath: String
        public var nameSource: String        // auto/user/fallback（CHECK 同值域）
        public var state: String             // active/missing/removed
        public var sizeBytes: Int64?
        public var mtime: Double?
        public var createdAt: Date
        public var updatedAt: Date
        public var removedAt: Date?

        public var id: UUID { documentID }

        public init(documentID: UUID, conversationID: UUID?, directoryName: String,
                    displayName: String, relativePath: String, nameSource: String,
                    state: String = "active", sizeBytes: Int64? = nil, mtime: Double? = nil,
                    createdAt: Date, updatedAt: Date, removedAt: Date? = nil) {
            self.documentID = documentID
            self.conversationID = conversationID
            self.directoryName = directoryName
            self.displayName = displayName
            self.relativePath = relativePath
            self.nameSource = nameSource
            self.state = state
            self.sizeBytes = sizeBytes
            self.mtime = mtime
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.removedAt = removedAt
        }
    }

    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// 建档/更新（按 document_id upsert）：镜像重建与「重新导出」共用。
    @discardableResult
    public func upsert(_ record: Record) async throws -> Record {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO document_user_export
                    (document_id, conversation_id, directory_name, display_name,
                     relative_path, name_source, state, size_bytes, mtime,
                     created_at, updated_at, removed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(document_id) DO UPDATE SET
                    conversation_id = excluded.conversation_id,
                    directory_name = excluded.directory_name,
                    display_name = excluded.display_name,
                    relative_path = excluded.relative_path,
                    name_source = excluded.name_source,
                    state = excluded.state,
                    size_bytes = excluded.size_bytes,
                    mtime = excluded.mtime,
                    updated_at = excluded.updated_at,
                    removed_at = excluded.removed_at
                """, arguments: [record.documentID.uuidString,
                                 record.conversationID?.uuidString,
                                 record.directoryName, record.displayName,
                                 record.relativePath, record.nameSource,
                                 record.state, record.sizeBytes, record.mtime,
                                 record.createdAt.timeIntervalSince1970,
                                 record.updatedAt.timeIntervalSince1970,
                                 record.removedAt?.timeIntervalSince1970])
        }
        return record
    }

    public func record(documentID: UUID) async -> Record? {
        (try? await writer.read { db in        // try?-ok: 读取失败按无记录呈现
            try Row.fetchOne(db, sql: """
                SELECT * FROM document_user_export WHERE document_id = ?
                """, arguments: [documentID.uuidString]).map(Self.record(from:))
        }).flatMap { $0 }
    }

    public func records(conversationID: UUID) async -> [Record] {
        (try? await writer.read { db in        // try?-ok: 读取失败按空集呈现
            try Row.fetchAll(db, sql: """
                SELECT * FROM document_user_export
                 WHERE conversation_id = ? AND removed_at IS NULL
                 ORDER BY created_at
                """, arguments: [conversationID.uuidString]).map(Self.record(from:))
        }) ?? []
    }

    /// 同目录已用显示名（去重基准；无会话的「直接导入」月桶按目录取）。
    public func records(directoryName: String) async -> [Record] {
        (try? await writer.read { db in        // try?-ok: 读取失败按空集呈现
            try Row.fetchAll(db, sql: """
                SELECT * FROM document_user_export
                 WHERE directory_name = ? AND removed_at IS NULL
                 ORDER BY created_at
                """, arguments: [directoryName]).map(Self.record(from:))
        }) ?? []
    }

    public func activeRecords() async -> [Record] {
        (try? await writer.read { db in        // try?-ok: 读取失败按空集呈现
            try Row.fetchAll(db, sql: """
                SELECT * FROM document_user_export
                 WHERE state = 'active' AND removed_at IS NULL
                 ORDER BY created_at
                """).map(Self.record(from:))
        }) ?? []
    }

    /// 漂移态流转（对账）：active → missing/removed；never 触碰 canonical 文件。
    public func setState(documentID: UUID, state: String,
                         sizeBytes: Int64? = nil, mtime: Double? = nil,
                         now: Date = Date()) async throws {
        try await writer.write { db in
            if state == "removed" {
                try db.execute(sql: """
                    UPDATE document_user_export
                       SET state = ?, size_bytes = COALESCE(?, size_bytes),
                           mtime = COALESCE(?, mtime), updated_at = ?, removed_at = ?
                     WHERE document_id = ?
                    """, arguments: [state, sizeBytes, mtime,
                                     now.timeIntervalSince1970, now.timeIntervalSince1970,
                                     documentID.uuidString])
            } else {
                try db.execute(sql: """
                    UPDATE document_user_export
                       SET state = ?, size_bytes = COALESCE(?, size_bytes),
                           mtime = COALESCE(?, mtime), updated_at = ?, removed_at = NULL
                     WHERE document_id = ?
                    """, arguments: [state, sizeBytes, mtime,
                                     now.timeIntervalSince1970, documentID.uuidString])
            }
        }
    }

    /// 清空全部/成员清理：账本整体擦除（先于文件树删除；文件删除由调用方执行）。
    public func wipe() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM document_user_export")
        }
    }

    private static func record(from row: Row) -> Record {
        Record(
            documentID: (row["document_id"] as String?).flatMap(UUID.init(uuidString:)) ?? UUID(),
            conversationID: (row["conversation_id"] as String?).flatMap(UUID.init(uuidString:)),
            directoryName: row["directory_name"] as String? ?? "",
            displayName: row["display_name"] as String? ?? "",
            relativePath: row["relative_path"] as String? ?? "",
            nameSource: row["name_source"] as String? ?? "auto",
            state: row["state"] as String? ?? "active",
            sizeBytes: row["size_bytes"] as Int64?,
            mtime: row["mtime"] as Double?,
            createdAt: Date(timeIntervalSince1970: row["created_at"] as Double? ?? 0),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double? ?? 0),
            removedAt: (row["removed_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
    }
}
#endif
