import Foundation

/// T1/T2 共用的模型互斥锁：同时只允许一个引擎持有模型资源。
/// 释放契约：引擎在 extract 出口处 `await release()`（成功/失败路径都到达；
/// 不用 defer —— defer 内 fire-and-forget 释放没有 happens-before，返回后
/// 注册表立即查 isOccupied 可能仍为真、把下一轨误判 modelBusy。release
/// 幂等，双路径重复释放无副作用）；电量/热状态感知降级在引擎侧。
/// 结构轮（2026-09-15）：自 FoundationModelsExtractionEngine.swift 迁出
/// ——「T1/T2 共用」的类型不属于任一引擎文件（P2）。
/// 审查修复（死代码清除）：原「30s 超时防死锁」宣称由 checkAndRelease 兜底，
/// 该方法全仓零调用、超时机制并不存在——且任意定时自动释放会在冷加载
/// （>30s 合法解码）中途解除互斥、放第二个模型并发驻留。移除假机制，
/// 释放契约改为文档化的 defer 单一事实。
public actor HeavyModelLease {
    public static let shared = HeavyModelLease()
    private var inUse = false
    private init() {}

    /// 尝试获取锁；返回 true = 成功，false = 已有引擎占用（调用方应降级到下一轨）。
    public func tryAcquire() -> Bool {
        guard !inUse else { return false }
        inUse = true
        return true
    }

    /// 释放锁。由两个引擎的 extract defer 保证（见类型注释的释放契约）。
    public func release() {
        inUse = false
    }

    /// 当前是否被占用。
    public var isOccupied: Bool { inUse }
}
