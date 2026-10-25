import Foundation

/// 早期注册的后台作业需要等待主界面会话就绪；`AppSession` 由 `ReadyAppRoot` 只创建一次后
/// 安装到本持有者。等待者只用于 BGTask 执行体，不参与 UI。
@MainActor
final class AppSessionHolder {
    static let shared = AppSessionHolder()

    private(set) var currentSession: AppSession?
    private var waiters: [CheckedContinuation<AppSession?, Never>] = []

    private init() {}

    func install(_ session: AppSession) {
        currentSession = session
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: session) }
    }

    /// 启动门失败：后台作业立即放弃本次执行（不无限挂起）。
    func fail() {
        currentSession = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: nil) }
    }

    func wait() async -> AppSession? {
        if let currentSession { return currentSession }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
