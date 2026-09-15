import Foundation

/// T1/T2 共用的模型互斥锁：同时只允许一个引擎持有模型资源。
/// 30s 超时防死锁；电量/热状态感知降级（`isThermalPressure`）。
/// 结构轮（2026-09-15）：自 FoundationModelsExtractionEngine.swift 迁出
/// ——「T1/T2 共用」的类型不属于任一引擎文件（P2）。
public actor HeavyModelLease {
    public static let shared = HeavyModelLease()
    private var inUse = false
    private var acquiredAt: ContinuousClock.Instant?
    private let timeout: Duration = .seconds(30)
    private init() {}

    /// 尝试获取锁；返回 true = 成功，false = 已有引擎占用（调用方应降级到下一轨）。
    public func tryAcquire() -> Bool {
        guard !inUse else { return false }
        inUse = true
        acquiredAt = ContinuousClock.now
        return true
    }

    /// 释放锁。超时后自动释放（`checkAndRelease` 定时调用）。
    public func release() {
        inUse = false
        acquiredAt = nil
    }

    /// 检查是否超时并自动释放。
    public func checkAndRelease() {
        guard let acquiredAt else { return }
        if ContinuousClock.now - acquiredAt >= timeout { release() }
    }

    /// 当前是否被占用。
    public var isOccupied: Bool { inUse }
}
