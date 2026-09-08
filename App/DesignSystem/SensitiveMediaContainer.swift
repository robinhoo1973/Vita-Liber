import SwiftUI
import Domain

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
    /// 空闲重锁任务（活跃信号重置窗口）
    @State private var relockTask: Task<Void, Never>?
    /// 解锁在途守卫：同步置位——连点两次只触发一次系统认证（unlocked 只在
    /// await 完成后翻转，双 Task 并发 requestUnlock 会产生两个并发
    /// LAContext 求值：第二个必败且可能双弹认证层）
    @State private var unlocking = false

    init(@ViewBuilder placeholder: @escaping (Bool) -> Placeholder,
         @ViewBuilder content: @escaping (Bool) -> Content) {
        self.placeholder = placeholder
        self.content = content
    }

    var body: some View {
        ZStack {
            placeholder(unlocked)
            if unlocked { content(unlocked) }
        }
        .onTapGesture {
            guard !unlocked, !unlocking else { return }
            // BR-007/BR-009（V3.22 修订）：无应用 PIN 后按 FR1.9 直接用系统设备所有者
            // 认证（Face ID/Touch ID + 设备密码兜底）。每次都是新弹系统浮层的独立认证。
            unlocking = true   // 同步置位（防连点双认证，见属性注）
            Task {
                if await app.requestUnlock(reason: L10n.sensitive_unlockReason) {
                    unlocked = true
                    scheduleRelock()
                }
                unlocking = false
            }
        }
        // 读图/点击/拖动/滚动均视为活跃——活跃即重置空闲重锁窗口
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            guard unlocked else { return }
            scheduleRelock()
        })
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, unlocked else { return }
            relock()
        }
        .onDisappear { relock() }
    }

    private func scheduleRelock() {
        relockTask?.cancel()
        let ttl = MediaUnlockPolicy.idleTTL
        relockTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000))   // try?-ok: 空闲重锁计时被取消即停，sleep 失败无副作用
            guard !Task.isCancelled else { return }
            relock()
        }
    }

    private func relock() {
        relockTask?.cancel()
        relockTask = nil
        unlocked = false
    }
}
