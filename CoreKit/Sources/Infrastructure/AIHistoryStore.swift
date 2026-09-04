#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// FR12.10 AI 会话历史数据仓（SP-51）：
/// 本地保存会话列表（时间/问题摘要/回答条数），可查看、删除单条、清空全部。
/// 删除仅移除会话本身，审计仍记录删除事实（调用方写 audit）。
/// 会话不跨成员串显（BR-001：查询强制 patient_id 过滤）。
public actor AIHistoryStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public struct Conversation: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var patientId: UUID
        public var title: String          // 首问摘要
        public var messageCount: Int
        public var createdAt: Date
        public init(id: UUID, patientId: UUID, title: String, messageCount: Int, createdAt: Date) {
            self.id = id; self.patientId = patientId; self.title = title
            self.messageCount = messageCount; self.createdAt = createdAt
        }
    }

    public struct Message: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var role: String
        public var content: String
        public var createdAt: Date
        public init(id: UUID, role: String, content: String, createdAt: Date) {
            self.id = id; self.role = role; self.content = content; self.createdAt = createdAt
        }
    }

    /// 开新会话（首问摘要作标题）
    @discardableResult
    public func startConversation(patientId: UUID, title: String,
                                  now: Date = Date()) async throws -> UUID {
        let id = UUID()
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO ai_conversation (id, patient_id, title, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString, title,
                                 now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
        return id
    }

    public func appendMessage(conversationId: UUID, role: String, content: String,
                              citationIds: String?, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO ai_message (id, conversation_id, role, content, citation_ids, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, conversationId.uuidString, role, content,
                                 citationIds, now.timeIntervalSince1970])
            try db.execute(sql: "UPDATE ai_conversation SET updated_at = ? WHERE id = ?",
                           arguments: [now.timeIntervalSince1970, conversationId.uuidString])
        }
    }

    public func conversations(patientId: UUID, limit: Int = 50) async throws -> [Conversation] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id, c.patient_id, c.title, c.created_at, COUNT(m.id) AS msg_count
                FROM ai_conversation c
                LEFT JOIN ai_message m ON m.conversation_id = c.id
                WHERE c.patient_id = ?
                GROUP BY c.id
                ORDER BY c.updated_at DESC LIMIT ?
                """, arguments: [patientId.uuidString, limit]).map { row in
                Conversation(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                             patientId: UUID(uuidString: row["patient_id"] as String) ?? UUID(),
                             title: row["title"] as String,
                             messageCount: Int(row["msg_count"] as Int64? ?? 0),
                             createdAt: Date(timeIntervalSince1970: row["created_at"] as Double))
            }
        }
    }

    public func messages(conversationId: UUID) async throws -> [Message] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, role, content, created_at FROM ai_message
                WHERE conversation_id = ? ORDER BY created_at ASC
                """, arguments: [conversationId.uuidString]).map { row in
                Message(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                        role: row["role"] as String,
                        content: row["content"] as String,
                        createdAt: Date(timeIntervalSince1970: row["created_at"] as Double))
            }
        }
    }

    /// FR12.10 删除单条（仅移除会话本身；审计由调用方记删除事实）
    public func deleteConversation(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM ai_message WHERE conversation_id = ?",
                           arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM ai_conversation WHERE id = ?",
                           arguments: [id.uuidString])
        }
    }

    /// FR12.10 清空全部（成员范围）
    public func clearAll(patientId: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                DELETE FROM ai_message WHERE conversation_id IN
                  (SELECT id FROM ai_conversation WHERE patient_id = ?)
                """, arguments: [patientId.uuidString])
            try db.execute(sql: "DELETE FROM ai_conversation WHERE patient_id = ?",
                           arguments: [patientId.uuidString])
        }
    }
}
#endif
