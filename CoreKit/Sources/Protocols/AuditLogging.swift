import Foundation

/// 审计日志写入（§5.6）：append-only，仅 INSERT 暴露。
/// 七类埋点（查看敏感原图/修改确认字段/删除/导出/AI scope/授权变更）由
/// Infrastructure 的 AuditLogWriter 实现、Store 装饰器统一调用。
public protocol AuditLogging: Sendable {
    /// 写入一条审计记录。entityId 由实现层哈希后落库（§6 日志最小化）。
    func record(action: String, entityType: String, entityId: String, actorLocal: String, meta: String?) async throws
}
