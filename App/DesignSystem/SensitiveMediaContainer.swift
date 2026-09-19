import SwiftUI
import Domain
import Perception

/// 空闲重锁计时器（SensitiveMediaContainer / SensitiveMediaOriginalView /
/// MediaUnlockSession 共用）：三者此前各自复制「cancel 旧任务 → sleep TTL →
/// isCancelled 判定 → 重锁」脚手架与 relockTask/unlockTask 双句柄管理——改
/// TTL 语义或取消纪律须同步三处且极易漏一处。策略常量仍在 Domain
/// `MediaUnlockPolicy`（idleTTL / showcaseTTL），本类型只持有任务句柄机制，
/// 重锁动作（清内存态/翻转 unlocked）仍归各消费视图。
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
        let clamped = ttl.isFinite && ttl > 0 ? ttl : MediaUnlockPolicy.idleTTL
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

/// 敏感媒体保护容器（BR-007/BR-008 · FR8.4 · tech-spec §5.10）。
///
/// 一处实现，所有敏感媒体界面复用：默认锁定 → 显式系统设备所有者认证解锁 →
/// 无操作自动重锁 → 退后台立即重锁。策略常量与判定全在 Domain `MediaUnlockPolicy`，
/// 本容器只负责 SwiftUI 侧的机制（计时任务、活跃手势、scenePhase、认证触发）。
///
/// **FR1.9 逐次解锁（V3.72）**：每次查看都是一次独立系统认证，**无会话级
/// 顺带解锁**——解锁态为本容器实例私有（@State），不跨视图共享：
/// 之前经全局 MediaUnlockSession 共享，解锁一张后 30 秒内其他敏感媒体
/// 零认证放行，与 FR1.9 明文相悖（function-spec 链序优先于 tech §5.10 旧设计；
/// 会话令牌保留给就诊展示模式 DoctorShowcase 300s 场景专用）。
struct SensitiveMediaContainer<Content: View, Placeholder: View>: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    /// 解锁后呈现的真实内容
    private let content: (Bool) -> Content
    /// 锁定态占位（绝不含可识别内容）
    private let placeholder: (Bool) -> Placeholder

    /// 本容器私有解锁态（FR1.9：无会话级顺带解锁）
    @State private var unlocked = false
    /// 空闲重锁计时器（计时/在途解锁双句柄，共享 MediaRelockTimer 机制）
    @State private var relockTimer = MediaRelockTimer()
    /// 解锁在途守卫：同步置位——连点两次只触发一次系统认证（unlocked 只在
    /// await 完成后翻转，双 Task 并发 requestUnlock 会产生两个并发
    /// LAContext 求值：第二个必败且可能双弹认证层）
    @State private var unlocking = false
    /// 认证成功时刻（inactive 重锁宽限锚点，MediaUnlockPolicy 判定用）
    @State private var unlockedAt: Date?
    /// 活跃信号合并（MediaUnlockPolicy.activityCoalescingWindow）：
    /// 触摸事件 60–120Hz 送达，逐事件重启计时任务 = 每帧 Task 分配/取消
    @State private var lastActivity: Date?

    init(@ViewBuilder placeholder: @escaping (Bool) -> Placeholder,
         @ViewBuilder content: @escaping (Bool) -> Content) {
        self.placeholder = placeholder
        self.content = content
    }

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                placeholder(unlocked)
                if unlocked { content(unlocked) }
            }
            .onTapGesture {
                guard !unlocked, !unlocking else { return }
                // BR-007/BR-009（V3.22 修订）：无应用 PIN 后按 FR1.9 直接用系统设备所有者
                // 认证（Face ID/Touch ID + 设备密码兜底）。每次都是新弹系统浮层的独立认证。
                unlocking = true   // 同步置位（防连点双认证，见属性注）
                let task = Task {
                    let ok = await app.requestUnlock(reason: L10n.sensitive_unlockReason)
                    // 重锁/离屏已取消本任务：认证结果不得复活解锁态
                    guard !Task.isCancelled else {
                        unlocking = false
                        return
                    }
                    if ok {
                        unlocked = true
                        unlockedAt = Date()
                        lastActivity = Date()
                        scheduleRelock()
                    }
                    unlocking = false
                }
                relockTimer.trackUnlock(task)
            }
            // 读图/点击/拖动/滚动均视为活跃——活跃即重置空闲重锁窗口；
            // 1 秒合并窗口（MediaUnlockPolicy.activityCoalescingWindow）
            // 滤掉 60–120Hz 触摸流的逐帧任务重启
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
                guard unlocked else { return }
                let now = Date()
                guard MediaUnlockPolicy.shouldRecordActivity(lastInteraction: lastActivity, now: now) else { return }
                lastActivity = now
                scheduleRelock()
            })
            .onChangeCompat(of: scenePhase) { _, phase in
                // 审查修复（2026-09-19，业主「认证后立即被自己的浮层重锁」）：
                // background = 真离开，恒立即重锁（BR-007/008 内存态纪律）；
                // inactive 可能是系统认证浮层收起瞬态——解锁后 5 秒内
                // 不重锁（MediaUnlockPolicy.shouldRelockOnInactive，
                // 「最低认证要求至少 5 秒」），浮层期间重锁会导致
                // 认证完成即锁回 → 再点再认证 = 循环。
                if phase == .background { relock() }
                else if phase != .active, unlocked,
                        MediaUnlockPolicy.shouldRelockOnInactive(lastUnlockAt: unlockedAt ?? Date(), now: Date()) {
                    relock()
                }
            }
            .onDisappear { relock() }
        }
    }

    private func scheduleRelock() {
        // 值捕获（View 结构体，与原先 Task 闭包同语义）：@State 写入经共享存储
        // 落真实状态，捕获的视图副本过时不影响。
        relockTimer.schedule(onExpiry: { relock() })
    }

    private func relock() {
        // 审查修复：重锁必须取消在途解锁任务——onDisappear/退后台的重锁
        // 拦不住无句柄的在途认证：认证完成后 unlocked=true 死而复生
        // （BR-007「重锁 = 回到认证前内存态」违反；SensitiveMediaOriginalView
        // 已修同族缺陷，本容器漏修）。
        relockTimer.cancelAll()
        // 同步复位在途守卫（与 SensitiveMediaOriginalView 同族修复）：
        // 被取消任务的复位有调度延迟，置位可避免回场首击被吞
        unlocking = false
        unlocked = false
        unlockedAt = nil
        lastActivity = nil
    }
}
