import Foundation

/// 「稍后再说」延期判定的纯函数（注入 now；7 天窗口）。
enum CatalogPromptDeferral {
    static let window: TimeInterval = 7 * 24 * 60 * 60

    static func isDeferred(now: Date, lastDeferredAt: Date?) -> Bool {
        guard let lastDeferredAt else { return false }
        return now.timeIntervalSince(lastDeferredAt) < window
    }
}

/// 完成后自动进入的调度器（可单测；取消后不再触发，重复调度被忽略）。
@MainActor
final class CatalogAutoEnterScheduler {
    private var task: Task<Void, Never>?

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return   // 取消：不得进入
            }
            guard !Task.isCancelled else { return }
            self?.task = nil
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
