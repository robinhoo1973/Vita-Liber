import Foundation
import Domain

/// §5.10 敏感媒体跨视图会话令牌：一次认证换取会话级解锁，连看多个敏感文件
/// 不必逐个验证。30s 无操作自动重锁；退后台立即重锁。
///
/// BR-007/BR-008: 敏感内容不跨生命周期存活——任务切换器快照、锁屏预览
/// 都不得出现敏感内容。会话令牌仅在 active scene 内有效。
@MainActor
@Observable
final class MediaUnlockSession {
    /// 会话是否处于解锁态
    private(set) var isUnlocked = false
    /// 最后一次交互时刻（用于 idle TTL 计算）
    private var lastInteraction: Date?
    /// 当前活跃的解锁任务（idle 超时取消用）
    private var idleTask: Task<Void, Never>?

    /// 解锁：写入令牌 + 启动 idle 计时 + 记录交互
    func unlock() {
        isUnlocked = true
        lastInteraction = Date()
        startIdleTimer()
    }

    /// 显式重锁（用户主动或退后台）
    func relock() {
        isUnlocked = false
        lastInteraction = nil
        idleTask?.cancel()
        idleTask = nil
    }

    /// 触摸/拖动/缩放等活跃信号：刷新 idle 时钟（合并窗口由调用方控制）
    func recordActivity() {
        let now = Date()
        guard MediaUnlockPolicy.shouldRecordActivity(lastInteraction: lastInteraction, now: now)
        else { return }
        lastInteraction = now
        // 交互刷新 → 重启 idle 计时
        startIdleTimer()
    }

    /// 退后台时由视图层调用
    func onBackground() {
        guard MediaUnlockPolicy.shouldRelockOnBackground() else { return }
        relock()
    }

    private func startIdleTimer() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(MediaUnlockPolicy.idleTTL * 1_000_000_000))
            } catch { return }
            await MainActor.run { self.relock() }
        }
    }
}
