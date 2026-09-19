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

    /// 医生展示模式会话 TTL（评审修正 H3）：spec V3.71/V3.72（§5.10 line 1379、
    /// §11 line 3149）将 MediaUnlockSession 预留给 DoctorShowcase 且锚定 300s——
    /// 此前会话令牌沿用手感 30s，任何后接消费方（嵌套媒体/后台校验）都会在
    /// 咨询中途被重锁。展示模式消费方必须用本值而非 idleTTL。
    public static let showcaseTTL: TimeInterval = 300

    /// 认证成功后的 inactive 重锁宽限（业主 2026-09-19：「最低认证要求应该
    /// 至少 5 秒而不是 0 秒」）。系统认证浮层（Face ID）呈现与收起都令场景
    /// 短暂进入 .inactive——收起瞬间的 .inactive 可能晚于 `unlocked = true`
    /// 送达（evaluatePolicy 续体与 scenePhase 投递同为主队列、顺序无契约），
    /// 5 秒内解锁立即被自己的浮层「重锁」→ 再点再认证 = 死循环。
    /// **本窗口只豁免 inactive**：background 恒立即重锁（BR-007/008
    /// 任务切换器/内存态纪律不受宽限影响；快照防泄露由
    /// `.privacySensitive(scenePhase != .active)` 承担，与重锁时刻解耦）。
    public static let postUnlockInactiveGrace: TimeInterval = 5

    /// 活跃信号合并窗口：触摸移动事件按 60–120Hz 送达，逐事件刷新时钟会让
    /// 计时任务每帧重启。1 秒粒度足够表达「仍在活跃」，对 30s 阈值无可感差异。
    public static let activityCoalescingWindow: TimeInterval = 1

    /// 解锁成功后、宽限窗口内收到 inactive 是否应当重锁。
    /// 纯谓词进 Domain（架构规则 4）：视图只报事件与时刻，判定不落 UI。
    public static func shouldRelockOnInactive(lastUnlockAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastUnlockAt) >= postUnlockInactiveGrace
    }

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
