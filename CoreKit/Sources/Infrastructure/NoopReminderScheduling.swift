import Foundation
import Domain
import Protocols

/// 只读降级容器专用调度器（2026-10-28 只读降级 B2）：全部 no-op。
///
/// 只读模式下**绝不排任何通知**（提醒排程=写副作用；零写红线延伸至系统面——
/// 降级期间用户看到的提醒状态必须与库内一致，不产生新投递）。查询面返回
/// 空集合（对账/窗口管理的读侧因此自然空转）。
public struct NoopReminderScheduling: ReminderScheduling {
    public init() {}

    public func schedule(dose notifyId: String, at fireAt: Date, route: AppRoute?) async throws {}
    public func schedule(dose notifyId: String, at fireAt: Date, route: AppRoute?,
                         patientId: UUID?) async throws {}
    public func scheduleRepeating(dose notifyId: String, at fireAt: Date, route: AppRoute?,
                                  repeatRule: String?) async throws {}
    public func cancel(_ notifyIds: [String]) async throws {}
    public func pending() async throws -> [String: Date] { [:] }
    public func delivered() async throws -> Set<String> { [] }
    public func removeDelivered(_ notifyIds: [String]) async throws {}
    public func reloadLocalizedContent() async throws {}
}
