#if os(iOS) || os(macOS)
// linux-blind: CryptoKit 哈希（Apple 专属模块，Linux 不可用） —— Linux 型检编译空单元，改动须经 macOS CI 验证
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
        "profile_suggestion_accepted",   // 子项目 D · D4-2：资料建议逐项接受（BR-003 D→C 显式确认；meta 只记留痕）
        // 全仓审查 2026-09-18（F-I1-02/F-I4 线索）：库存归真此前在 MedicationStore
        // 事务内绕过本白名单直写 audit_event——action 不在集合内即「类型约束」失守。
        // 登记后 MedicationStore 改经 `insert(..., db:)` 同事务写入，白名单成唯一出口。
        "inventory.reconcile",
    ]

    /// 审计动作常量（App 层调用点此前以字面量拼写，"viewSensitiveOriginal" 从未命中
    /// 白名单——FR14.2「查看敏感原图」审计从未落库、只在 Logger 留错）。
    /// 调用方一律引用常量，拼写错误在编译期暴露。
    public enum Action {
        public static let viewSensitive = "view_sensitive"
        public static let confirmField = "confirm_field"
        public static let delete = "delete"
        public static let export = "export"
        public static let aiScope = "ai_scope"
        public static let grantChange = "grant_change"
        public static let unlock = "unlock"
        public static let create = "create"
        public static let update = "update"
        public static let feedback = "feedback"
        public static let profileSuggestionAccepted = "profile_suggestion_accepted"
        public static let inventoryReconcile = "inventory.reconcile"
    }
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public func record(action: String, entityType: String, entityId: String,
                       actorLocal: String, meta: String?) async throws {
        guard Self.allowedActions.contains(action) else {
            throw AuditError.actionNotAllowed(action)
        }
        try await writer.write { db in
            try Self.insert(action: action, entityType: entityType, entityId: entityId, actorLocal: actorLocal, meta: meta, db: db)
        }
    }

    /// 同事务写入口，供关系更新与事实写门复用；不引入第二个数据库事务。
    static func insert(action: String, entityType: String, entityId: String, actorLocal: String,
                       meta: String?, db: Database) throws {
        guard allowedActions.contains(action) else { throw AuditError.actionNotAllowed(action) }
        let hash = CryptoKitContentHasher().sha256Hex(Data(entityId.utf8))
        try db.execute(
                sql: """
                INSERT INTO audit_event (id, actor_local, action, entity_type, entity_id_hash, at, meta_json)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [UUID().uuidString, actorLocal, action, entityType, hash,
                            Date().timeIntervalSince1970, meta])
    }

    public enum AuditError: Error, LocalizedError, Sendable {
        case actionNotAllowed(String)
        public var errorDescription: String? { "审计动作不在白名单: \(self)" }
    }
}
#endif
