import Foundation

/// tech-spec §1.1 分层第三层：Protocols —— 存储与系统服务的能力锚点。
/// M0 最小面（评审 S1-3：§3.1② 要求 CoreKit 三目标骨架，Domain/Protocols/Infrastructure）：
/// Feature 面向协议、Infrastructure 提供实现；跨 Feature 通信只经 Domain 实体与本层协议。

/// 数据读写上下文（GRDB DatabaseWriter 的最小抽象——Infrastructure 之外不 import GRDB）。
/// M0 语义面：读与写必须落在同一事务性上下文（§4.4 串行写）。
public protocol DatabaseContext: Sendable {
    /// 在上下文内执行读操作并返回结果。
    func read<T>(_ body: @Sendable (any ReadAccess) throws -> T) throws -> T
    /// 在上下文内执行写操作（事务内串行执行）。
    func write<T>(_ body: @Sendable (any WriteAccess) throws -> T) throws -> T
}

/// 读侧能力（M0 最小面）。
public protocol ReadAccess: Sendable {}

/// 写侧能力（M0 最小面）。
public protocol WriteAccess: Sendable {}

/// 审计日志写入（§5.6）：append-only，仅 INSERT 暴露。
/// 七类埋点（查看敏感原图/修改确认字段/删除/导出/AI scope/授权变更）由
/// Infrastructure 的 AuditLogWriter 实现、Store 装饰器统一调用。
public protocol AuditLogging: Sendable {
    /// 写入一条审计记录。entityId 由实现层哈希后落库（§6 日志最小化）。
    func record(action: String, entityType: String, entityId: String, actorLocal: String, meta: String?) async throws
}
