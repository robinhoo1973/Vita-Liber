import SwiftUI
import Domain
import Perception

/// 空闲重锁计时器（MediaUnlockSession 使用）：此前查看器各自复制
/// 「cancel 旧任务 → sleep TTL → isCancelled 判定 → 重锁」脚手架与
/// relockTask/unlockTask 双句柄管理——改 TTL 语义或取消纪律须同步多处且
/// 极易漏一处。策略常量仍在 Domain `MediaUnlockPolicy`
///（idleTTL / showcaseTTL），本类型只持有任务句柄机制，重锁动作仍归
/// 消费方。
///
/// 结构体形态（非 @Observable、非 @MainActor 标注）：经 `@State` 持有，
/// 只含引用类型字段（Task），读改写时复制零代价。计时 Task 显式标注
/// `@MainActor`——本方法为 nonisolated（Task 继承**词法**上下文而非调用方
/// 上下文），不显式标注会把重锁回调投到全局并发执行器、后台线程写 @State。
struct MediaRelockTimer {
    /// 空闲重锁计时句柄（活跃信号重置窗口）
    private var relockTask: Task<Void, Never>?
    /// 在途解锁任务句柄——重锁/离屏必须取消，否则认证结果在重锁后复活
    /// 解锁态（BR-007「重锁 = 回到认证前内存态」）。
    private var unlockTask: Task<Void, Never>?

    /// 武装空闲重锁计时：先取消旧计时，TTL 到期且未取消时回调 onExpiry。
    mutating func schedule(ttl: TimeInterval = MediaUnlockPolicy.idleTTL,
                           onExpiry: @escaping () -> Void) {
        relockTask?.cancel()
        // 域钳制（审查修复）：UInt64(ttl × 1e9) 对负数/NaN/天文值运行时
        // trap。当前调用方恒传 MediaUnlockPolicy 常量（30/300），但任何
        // 未来注入存储/备份恢复值（门禁宽限同族脏数据，AppRootView 已
        // 为此钳制）都会崩——钳制进本机制而非依赖调用方自律。
        // 第九轮审查修复：仅判 finite/正数不够——超大**有限**值（> ~584 年，
        // 如 1e12）乘以 1e9 仍超 UInt64.max，UInt64 转换照旧硬陷阱。补上界。
        let clamped = ttl.isFinite && ttl > 0 ? min(ttl, 24 * 3600) : MediaUnlockPolicy.idleTTL
        relockTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))   // try?-ok: 空闲重锁计时被取消即停，sleep 失败无副作用；clamped 已钳制，无溢出
            guard !Task.isCancelled else { return }
            onExpiry()
        }
    }

    /// 登记在途解锁任务（重锁/离屏取消用）。
    mutating func trackUnlock(_ task: Task<Void, Never>) {
        unlockTask = task
    }

    /// 取消空闲计时与在途解锁任务（各消费方的重锁动作第一步）。
    mutating func cancelAll() {
        relockTask?.cancel()
        relockTask = nil
        unlockTask?.cancel()
        unlockTask = nil
    }
}
