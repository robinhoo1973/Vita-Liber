// 平台守卫镜像 Package.swift（ERR#8 纪律）
#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

/// FR24.2 发送状态仓储（actor）。
///
/// - `recordSent`：分享完成后落一条 `sent` 记录（**不存原文**，最小必要）；
/// - `updateStatus`：状态迁移经 Domain `MessageStatusRules` 白名单校验，
///   回退与旁路跳变一律拒绝（acked 不能回到 sent——状态不可伪造）；
/// - `list`：按成员、时间倒序。
public actor MessageDeliveryStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public enum StoreError: Error, LocalizedError {
        case illegalTransition(String)
        case notFound
        public var errorDescription: String? { "发送状态操作失败: \(self)" }
    }

    public func recordSent(patientId: UUID, kind: String, recipient: String,
                           at: Date = Date()) async throws -> SentMessage {
        let message = SentMessage(kind: kind, recipient: recipient, status: .sent, sentAt: at)
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO sent_message (id, patient_id, kind, recipient, status, sent_at, updated_at)
                VALUES (?, ?, ?, ?, 'sent', ?, ?)
                """, arguments: [message.id.uuidString, patientId.uuidString, kind, recipient,
                                 at.timeIntervalSince1970, at.timeIntervalSince1970])
        }
        return message
    }

    /// 状态迁移（P1/D1 云端回执接入后调用；M2 只产生 sent）。
    /// 白名单校验在 Domain——Repository 不自行裁决状态机。
    public func updateStatus(id: UUID, to newStatus: MessageStatus,
                             at: Date = Date()) async throws {
        try await writer.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT status FROM sent_message WHERE id = ?
                """, arguments: [id.uuidString]) else {
                throw StoreError.notFound
            }
            guard let current = MessageStatus(rawValue: row["status"] as String),
                  MessageStatusRules.canTransition(from: current, to: newStatus) else {
                throw StoreError.illegalTransition("\(row["status"] as String) → \(newStatus.rawValue)")
            }
            try db.execute(sql: """
                UPDATE sent_message SET status = ?, updated_at = ? WHERE id = ?
                """, arguments: [newStatus.rawValue, at.timeIntervalSince1970, id.uuidString])
        }
    }

    public func list(patientId: UUID) async throws -> [SentMessage] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM sent_message WHERE patient_id = ?
                ORDER BY sent_at DESC
                """, arguments: [patientId.uuidString])
            return rows.map { row in
                SentMessage(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                            kind: row["kind"] as String,
                            recipient: row["recipient"] as String,
                            status: MessageStatus(rawValue: row["status"] as String) ?? .sent,
                            sentAt: Date(timeIntervalSince1970: row["sent_at"] as Double))
            }
        }
    }
}
#endif
