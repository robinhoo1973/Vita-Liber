import Foundation

/// 早期注册的后台作业需要等待主界面会话就绪。会话由启动门在容器就绪时
/// 安装一次；等待者只用于 BGTask 执行体，不参与 UI。
///
/// 终态纪律（2026-10-27 审查 P1）：
/// - 系统到期会取消后台 Task，取消必须能结束 `wait()`（否则 continuation
///   永不 resume，`setTaskCompleted` 不调用，进程被系统杀死）。
/// - 启动失败后新来的等待者立即返回 nil（sticky failed），不再无限挂起；
///   用户重试时 `resetForRetry()` 恢复可等待。
@MainActor
final class AppSessionHolder {
    static let shared = AppSessionHolder()

    private enum State {
        case pending
        case installed(AppSession)
        case failed
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<AppSession?, Never>
    }

    private var state: State = .pending
    private var waiters: [Waiter] = []

    private init() {}

    var currentSession: AppSession? {
        if case .installed(let session) = state { return session }
        return nil
    }

    func install(_ session: AppSession) {
        if case .installed(let existing) = state, existing === session { return }
        state = .installed(session)
        resumeAll(with: session)
    }

    /// 启动门失败：立即放行所有等待者（nil），并进入 sticky failed。
    func fail() {
        guard case .failed = state else {
            state = .failed
            resumeAll(with: nil)
            return
        }
    }

    /// 用户重试：失败终态复位为可等待。
    func resetForRetry() {
        if case .failed = state { state = .pending }
    }

    /// 有界等待：取消或超时都返回 nil，绝不无限挂起。
    func wait(timeout: Duration = .seconds(15)) async -> AppSession? {
        switch state {
        case .installed(let session): return session
        case .failed: return nil
        case .pending: break
        }
        if Task.isCancelled { return nil }
        let id = UUID()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout) // try?-ok: 取消即结束计时
            await self?.expire(id)
        }
        let session: AppSession? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.expire(id) }
        }
        timeoutTask.cancel()
        return session
    }

    private func expire(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }

    private func resumeAll(with session: AppSession?) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(returning: session) }
    }
}
