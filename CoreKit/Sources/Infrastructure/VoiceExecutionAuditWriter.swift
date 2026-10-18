#if os(iOS) || os(macOS)
// linux-blind: GRDB 审计事务仅 iOS/macOS 链接（ERR#8 纪律），Linux 编译空单元，
// 改动须经 macOS CI 验证。
import Foundation
import GRDB
import Domain

/// V13：语音/文本助手动作与审计同事务。
///
/// 审计表同时充当**幂等账本**：同 `idempotencyKey` 的 `voice.execute` 若已存在，
/// 业务行不得重复插入（跨启动有效，不依赖内存态）。审计 meta 由
/// `VoiceExecutionAudit.metaJSON` 生成，零 PHI。
enum VoiceExecutionAuditWriter {
    static func hasExecuted(_ idempotencyKey: String, db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: """
            SELECT 1 FROM audit_event
            WHERE action = ? AND json_extract(meta_json, '$.idempotencyKey') = ?
            LIMIT 1
            """, arguments: [AuditLogWriter.Action.voiceExecute, idempotencyKey]) != nil
    }

    /// 同事务写入；返回 false = 幂等重放（未写第二行）。
    @discardableResult
    static func record(_ audit: VoiceExecutionAudit, entityType: String, entityId: String,
                       db: Database) throws -> Bool {
        guard try !hasExecuted(audit.idempotencyKey, db: db) else { return false }
        try AuditLogWriter.insert(action: AuditLogWriter.Action.voiceExecute,
                                  entityType: entityType, entityId: entityId,
                                  actorLocal: audit.actorLocal, meta: audit.metaJSON, db: db)
        return true
    }
}
#endif
