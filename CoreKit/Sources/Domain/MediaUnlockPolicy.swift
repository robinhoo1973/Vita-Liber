import Foundation

/// 敏感媒体解锁/重锁策略（BR-007/BR-008 · FR8.4 · tech-spec §5.10）。
///
/// 为什么是 Domain 纯函数：重锁时机是业务规则（架构规则 4「BR 规则是 Domain 纯函数」），
/// 而不是某个视图的实现细节。此前 30 秒阈值与「按无操作计时」的语义只长在
/// `LockedMediaView` 内部，导致：
/// ① 规则无法单测（要起 SwiftUI 视图才能验证重锁时机）；
/// ② 每个敏感媒体界面（文档查看器、帮助卡照片、§5.38 医生展示模式）都要重新推导一遍，
///    历史上已经漂移过一次（「解锁后固定 30s」→「30s 无操作」）。
///
/// 计时口径是**最后一次交互**而非解锁时刻：正在读图/缩放的用户不该被打断，
/// 而放下手机的用户必须尽快回到锁定态。
public enum MediaUnlockPolicy: Sendable {
    /// 无操作后自动重锁的阈值（tech-spec §5.10：30s TTL）
    public static let idleTTL: TimeInterval = 30

    /// 活跃信号合并窗口：触摸移动事件按 60–120Hz 送达，逐事件刷新时钟会让
    /// 计时任务每帧重启。1 秒粒度足够表达「仍在活跃」，对 30s 阈值无可感差异。
    public static let activityCoalescingWindow: TimeInterval = 1

    /// 是否应当重锁（以最后一次交互为起点）
    public static func shouldRelock(lastInteraction: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastInteraction) >= idleTTL
    }

    /// 这次活跃信号是否需要落到状态里（合并窗口内的重复信号直接丢弃）
    public static func shouldRecordActivity(lastInteraction: Date?, now: Date) -> Bool {
        guard let lastInteraction else { return true }
        return now.timeIntervalSince(lastInteraction) >= activityCoalescingWindow
    }

    /// 退到非活跃态是否立即重锁——敏感内容不跨生命周期存活
    /// （BR-007/008：任务切换器快照、锁屏预览都不得出现敏感内容）
    public static func shouldRelockOnBackground() -> Bool { true }
}
