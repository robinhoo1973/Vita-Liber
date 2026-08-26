import Foundation
import Domain

/// 通知调度端口（§5.4）：生产实现 UNReminderScheduler（UNUserNotificationCenter），
/// 测试实现 InMemoryReminderScheduler——提醒可靠性四用例以注入桩验证，
/// 生产路径零改动（test-plan E7）。
public protocol ReminderScheduling: Sendable {
    /// 调度一条剂量提醒；body 传通用占位（锁屏隐私：默认「您有一条健康提醒」）
    func schedule(dose notifyId: String, at fireAt: Date) async throws
    func cancel(_ notifyIds: [String]) async throws
    /// pending 表：notifyId → fireAt（对账与窗口管理用）
    func pending() async throws -> [String: Date]
    /// 已送达标识集合
    func delivered() async throws -> Set<String>
}

/// 剂量事实源（对账输入）：dose_log 查询投影
public protocol DoseSource: Sendable {
    func deliveryFacts(from: Date, to: Date) async throws -> [DoseDeliveryFact]
    func markAwaitingUser(_ notifyId: String) async throws
}

/// 测试/Preview 内存实现
public actor InMemoryReminderScheduler: ReminderScheduling {
    private var pendingMap: [String: Date] = [:]
    private var deliveredSet: Set<String> = []

    public init() {}

    public func schedule(dose notifyId: String, at fireAt: Date) async throws {
        pendingMap[notifyId] = fireAt
    }
    public func cancel(_ notifyIds: [String]) async throws {
        for id in notifyIds { pendingMap.removeValue(forKey: id) }
    }
    public func pending() async throws -> [String: Date] { pendingMap }
    public func delivered() async throws -> Set<String> { deliveredSet }

    /// 测试辅助：模拟系统送达（把 pending 移入 delivered）
    public func simulateDelivery(upTo now: Date) async {
        let fired = pendingMap.filter { $0.value <= now }
        for (id, _) in fired {
            pendingMap.removeValue(forKey: id)
            deliveredSet.insert(id)
        }
    }
    /// 测试辅助：模拟杀进程重启（清空系统侧 pending，delivered 保留）
    public func simulateRestart() async {
        pendingMap.removeAll()
    }
}
