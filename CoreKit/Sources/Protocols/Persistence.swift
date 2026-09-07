import Foundation

/// tech-spec §1.1 分层第三层：Protocols —— 存储与系统服务的能力锚点。
/// M0 最小面（评审 S1-3：§3.1② 要求 CoreKit 三目标骨架，Domain/Protocols/Infrastructure）：
/// Feature 面向协议、Infrastructure 提供实现；跨 Feature 通信只经 Domain 实体与本层协议。
///
/// 第八轮全仓审查修复：DatabaseContext/ReadAccess/WriteAccess 三元组（M0
/// 最小面空标记脚手架）全仓零实现、零引用——各 Store 直接持有 DatabaseWriter，
/// 协议层从未强制「同一事务上下文」纪律，协议演进时也无人发现没有实现方。
/// 已删除（§4.4 纪律由 Infrastructure 的 DatabaseWriter 注入点强制执行，
/// tech-spec 保留描述）。

/// 审计日志写入（§5.6）：append-only，仅 INSERT 暴露。
/// 七类埋点（查看敏感原图/修改确认字段/删除/导出/AI scope/授权变更）由
/// Infrastructure 的 AuditLogWriter 实现、Store 装饰器统一调用。
public protocol AuditLogging: Sendable {
    /// 写入一条审计记录。entityId 由实现层哈希后落库（§6 日志最小化）。
    func record(action: String, entityType: String, entityId: String, actorLocal: String, meta: String?) async throws
}

/// ADR-008 铝箔板盘点技术验证（P2 视觉）占位端口。
///
/// M3 零阻塞项只做**技术验证的验证**：确认「OCR 派生条目必待确认（BR-003）」
/// 这条纪律在铝箔板识别场景的落点——计数识别结果一律 D 级，绝不自动作数。
/// 真机 Vision 实现归 P2；此占位让 BR-003 在协议层就有约束。
public protocol InventoryScanner: Sendable {
    /// 从铝箔板图像识别剩余药片数。结果恒 D 级待确认（BR-003）。
    func scanBlisterCount(_ imageData: Data) async throws -> BlisterScanResult
}

public struct BlisterScanResult: Sendable, Equatable {
    public var count: Int
    /// 恒 false —— 机器识别计数是候选不是事实，入库前必须用户确认
    public var autoConfirmed: Bool { false }
    public init(count: Int) { self.count = count }
}

public actor StubInventoryScanner: InventoryScanner {
    private let scriptedCount: Int
    public init(count: Int = 0) { self.scriptedCount = count }
    public func scanBlisterCount(_ imageData: Data) async throws -> BlisterScanResult {
        BlisterScanResult(count: scriptedCount)
    }
}
