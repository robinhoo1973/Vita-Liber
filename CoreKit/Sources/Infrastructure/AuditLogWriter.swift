#if os(iOS) || os(macOS)
import Foundation
import CryptoKit
import GRDB
import Protocols

/// §5.6 审计日志写入口（append-only，仅 INSERT 暴露）。
/// 白名单 action 集合 + entity_id 哈希落库——「只记事实与计数、不记医疗内容」
/// 从注释约束升格为类型约束（评审 S2-1 修正）。
public struct AuditLogWriter: AuditLogging, Sendable {
    public static let allowedActions: Set<String> = [
        "view_sensitive", "confirm_field", "delete", "export",
        "ai_scope", "grant_change", "unlock", "create", "update",
        "feedback",        // FR6.7 识别问题报告 / FR12.8 AI 反馈（本地记录，P1 上报）
    ]
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public func record(action: String, entityType: String, entityId: String,
                       actorLocal: String, meta: String?) async throws {
        guard Self.allowedActions.contains(action) else {
            throw AuditError.actionNotAllowed(action)
        }
        let hash = CryptoKit.SHA256.hash(data: Data(entityId.utf8))
            .map { String(format: "%02x", $0) }.joined()   // ADR-025：审计脱敏走 CryptoKit
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO audit_event (id, actor_local, action, entity_type, entity_id_hash, at, meta_json)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [UUID().uuidString, actorLocal, action, entityType, hash,
                            Date().timeIntervalSince1970, meta])
        }
    }

    public enum AuditError: Error, LocalizedError, Sendable {
        case actionNotAllowed(String)
        public var errorDescription: String? { "审计动作不在白名单: \(self)" }
    }
}
#endif
