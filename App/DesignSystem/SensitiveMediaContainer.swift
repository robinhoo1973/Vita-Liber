import SwiftUI
import Domain

/// 敏感媒体保护容器（BR-007/BR-008 · FR8.4 · tech-spec §5.10）。
///
/// 一处实现，所有敏感媒体界面复用：默认锁定 → 显式系统设备所有者认证解锁 →
/// 无操作自动重锁 → 退后台立即重锁。策略常量与判定全在 Domain `MediaUnlockPolicy`，
/// 本容器只负责 SwiftUI 侧的机制（计时任务、活跃手势、scenePhase、认证触发）。
///
/// §5.10 会话令牌：跨视图共享解锁状态——一次认证换取会话级解锁，
/// 连看多个敏感文件不必逐个验证。
struct SensitiveMediaContainer<Content: View, Placeholder: View>: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(MediaUnlockSession.self) private var session

    /// 解锁后呈现的真实内容
    private let content: (Bool) -> Content
    /// 锁定态占位（绝不含可识别内容）
    private let placeholder: (Bool) -> Placeholder

    init(@ViewBuilder placeholder: @escaping (Bool) -> Placeholder,
         @ViewBuilder content: @escaping (Bool) -> Content) {
        self.placeholder = placeholder
        self.content = content
    }

    var body: some View {
        ZStack {
            placeholder(session.isUnlocked)
            if session.isUnlocked { content(session.isUnlocked) }
        }
        .onTapGesture {
            guard !session.isUnlocked else { return }
            // BR-007/BR-009（V3.22 修订）：无应用 PIN 后按 FR1.9 直接用系统设备所有者
            // 认证（Face ID/Touch ID + 设备密码兜底）。每次都是新弹系统浮层的独立认证，
            // 不存在「顺带解锁」语义问题——成功即放行本容器。
            Task {
                if await app.requestUnlock(reason: L10n.sensitive_unlockReason) {
                    session.unlock()
                }
            }
        }
        // 读图/点击/拖动/滚动均视为活跃（DragGesture(minimumDistance: 0) 覆盖按下与拖动）；
        // 活跃信号经 Domain 合并窗口去抖，避免每帧写状态
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            guard session.isUnlocked else { return }
            session.recordActivity()
        })
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            session.onBackground()
        }
    }
}
