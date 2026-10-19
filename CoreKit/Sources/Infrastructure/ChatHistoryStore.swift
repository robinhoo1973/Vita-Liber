#if os(iOS) || os(macOS)
// linux-blind: GRDB（Apple 平台依赖）—— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Protocols

/// AI 聊天历史（2026-10-19 业主指令）：本机会话与消息。
///
/// 隐私纪律：本表只存展示快照（文本/媒体文件名/信息卡摘要），不复制病历事实；
/// 零网络、零遥测。删除会话 = 真删（消息级联），清空全部时整表擦除。
public actor ChatHistoryStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public struct ConversationSummary: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var title: String
        public var preview: String
        public var updatedAt: Date
        public var pinned: Bool
        public var messageCount: Int
    }

    public struct StoredMessage: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var role: String
        public var kind: String
        public var text: String
        public var payloadJSON: String?
        public var createdAt: Date
        public var ordinal: Int
    }

    @discardableResult
    public func createConversation(patientId: UUID, title: String,
                                   at now: Date = Date()) throws -> UUID {
        let id = UUID()
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO chat_conversation (id, patient_id, title, pinned, created_at, updated_at)
                VALUES (?, ?, ?, 0, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString, title,
                                 now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
        return id
    }

    @discardableResult
    public func appendMessage(conversationId: UUID, role: String, kind: String,
                              text: String, payloadJSON: String?,
                              at now: Date = Date()) throws -> UUID {
        let id = UUID()
        try await writer.write { db in
            let next = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(ordinal), 0) + 1 FROM chat_message WHERE conversation_id = ?
                """, arguments: [conversationId.uuidString]) ?? 1
            try db.execute(sql: """
                INSERT INTO chat_message (id, conversation_id, role, kind, text, payload_json, created_at, ordinal)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, conversationId.uuidString, role, kind, text,
                                 payloadJSON, now.timeIntervalSince1970, next])
            try db.execute(sql: "UPDATE chat_conversation SET updated_at = ? WHERE id = ?",
                           arguments: [now.timeIntervalSince1970, conversationId.uuidString])
        }
        return id
    }

    /// 卡片状态快照更新（完成勾 / 转待办）：只改 payload 内状态，不动消息内容。
    public func updateCardSnapshot(conversationId: UUID, cardId: String, state: String) throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE chat_message
                SET payload_json = json_set(payload_json, '$.card.snapshotState', ?)
                WHERE conversation_id = ? AND kind = 'card'
                  AND json_extract(payload_json, '$.card.id') = ?
                """, arguments: [state, conversationId.uuidString, cardId])
        }
    }

    public func rename(_ id: UUID, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await writer.write { db in
            try db.execute(sql: "UPDATE chat_conversation SET title = ? WHERE id = ?",
                           arguments: [String(trimmed.prefix(60)), id.uuidString])
        }
    }

    public func setPinned(_ id: UUID, pinned: Bool) throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE chat_conversation SET pinned = ? WHERE id = ?",
                           arguments: [pinned ? 1 : 0, id.uuidString])
        }
    }

    public func delete(_ id: UUID) throws {
        try await writer.write { db in
            _ = try ChatConversationRow.deleteOne(db, key: id.uuidString)
        }
    }

    public func conversations(patientId: UUID, query: String = "") throws -> [ConversationSummary] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let like = "%\(term)%"
        return try await writer.read { db in
            let sql = """
                SELECT c.id, c.title, c.pinned, c.updated_at,
                  (SELECT COUNT(*) FROM chat_message m WHERE m.conversation_id = c.id) AS message_count,
                  (SELECT COALESCE(NULLIF(m.text, ''),
                                   json_extract(m.payload_json, '$.media.filename'),
                                   json_extract(m.payload_json, '$.card.title'), '')
                     FROM chat_message m WHERE m.conversation_id = c.id
                     ORDER BY m.ordinal DESC LIMIT 1) AS preview
                FROM chat_conversation c
                WHERE c.patient_id = ?
                  AND (? = ''
                       OR c.title LIKE ?
                       OR EXISTS (SELECT 1 FROM chat_message m
                                  WHERE m.conversation_id = c.id AND m.text LIKE ?))
                ORDER BY c.pinned DESC, c.updated_at DESC
                LIMIT 300
                """
            return try Row.fetchAll(db, sql: sql, arguments: [patientId.uuidString, term, like, like])
                .map { row in
                    ConversationSummary(
                        id: UUID(uuidString: row["id"] as String? ?? "") ?? UUID(),
                        title: row["title"] as String? ?? "",
                        preview: row["preview"] as String? ?? "",
                        updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double? ?? 0),
                        pinned: (row["pinned"] as Int? ?? 0) == 1,
                        messageCount: row["message_count"] as Int? ?? 0)
                }
        }
    }

    public func messages(conversationId: UUID) throws -> [StoredMessage] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, role, kind, text, payload_json, created_at, ordinal
                FROM chat_message WHERE conversation_id = ? ORDER BY ordinal ASC
                """, arguments: [conversationId.uuidString]).map { row in
                StoredMessage(
                    id: UUID(uuidString: row["id"] as String? ?? "") ?? UUID(),
                    role: row["role"] as String? ?? "user",
                    kind: row["kind"] as String? ?? "text",
                    text: row["text"] as String? ?? "",
                    payloadJSON: row["payload_json"] as String?,
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double? ?? 0),
                    ordinal: row["ordinal"] as Int? ?? 0)
            }
        }
    }

    public func count(patientId: UUID) throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_conversation WHERE patient_id = ?",
                             arguments: [patientId.uuidString]) ?? 0
        }
    }

    /// 清空全部 / 隐私擦除：整表真删（消息由 FK 级联）。
    public func wipeAll() throws {
        try await writer.write { db in
            _ = try ChatConversationRow.deleteAll(db)
        }
    }
}

/// GRDB 删除辅助（仅提供表名与主键映射）。
private struct ChatConversationRow: TableRecord, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chat_conversation"
    var id: String
}
#endif
