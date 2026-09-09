import Foundation
import Domain

/// FR17.9/FR17.18 端侧文本润色端口（tech §5.13 `TextRefining` / `LocalTranscriptRefiner`）：
/// 输入原生转写，输出 `TranscriptRevision`——**永不覆盖原文**，建议经 `ProtectedTokenValidator`
/// 校验后才 `.accepted`；不可用/超时/校验失败一律回原文，保存与 FR17.13 确认路径不被阻塞。
/// 端侧、零网络（EAL `onDeviceOnly`）；紧急关键词在润色前判定（BR-012）、措辞负清单在展示前过滤（BR-006）。
public protocol TextRefining: Sendable {
    /// 本机是否可用（Foundation Models 可用性 + 平台门控；不含用户授权——授权由 App 层 authAI 门控）
    var isAvailable: Bool { get async }
    /// Format-only suggestions. Vocabulary must never be treated as complete entity protection.
    func refine(_ original: String, localeIdentifier: String, drugNames: [String]) async -> TranscriptRevision
}

/// 不可用替身（iOS < 26 / 非 Apple 平台 / 模型未就绪）：诚实返回 `.unavailable`，效果 = 原文。
public struct UnavailableTextRefiner: TextRefining {
    public init() {}
    public var isAvailable: Bool { get async { false } }
    public func refine(_ original: String, localeIdentifier: String, drugNames: [String]) async -> TranscriptRevision {
        .unavailable(original)
    }
}

/// Bounds the caller's wait and admits only one native generation, even if cancellation is ignored.
/// The slot remains reserved until both native work and cancellation delivery exit.
public final class RefinementDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Request?

    public init() {}

    public func run(original: String, timeout: Duration,
                    operation: @escaping @Sendable () async throws -> TranscriptRevision) async -> TranscriptRevision {
        guard !Task.isCancelled else { return .unavailable(original) }
        guard timeout > .zero else { return .timedOut(original) }
        let request = Request(original: original, deadline: ContinuousClock().now.advanced(by: timeout))
        guard reserve(request) else { return .unavailable(original) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.start(continuation, operation: operation) { self.release(request) }
            }
        } onCancel: {
            request.finish(.unavailable(original))
        }
    }

    private func reserve(_ request: Request) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active == nil else { return false }
        active = request
        return true
    }

    private func release(_ request: Request) {
        lock.lock()
        defer { lock.unlock() }
        if active === request { active = nil }
    }

    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private let original: String
        private let deadline: ContinuousClock.Instant
        private let clock = ContinuousClock()
        private var outcome: TranscriptRevision?
        private var continuation: CheckedContinuation<TranscriptRevision, Never>?
        private var work: Task<Void, Never>?
        private var timer: Task<Void, Never>?
        private var workFinished = false
        private var cancellationFinished = true
        private var onWorkFinished: (@Sendable () -> Void)?

        init(original: String, deadline: ContinuousClock.Instant) {
            self.original = original
            self.deadline = deadline
        }

        func start(_ continuation: CheckedContinuation<TranscriptRevision, Never>,
                   operation: @escaping @Sendable () async throws -> TranscriptRevision,
                   onWorkFinished: @escaping @Sendable () -> Void) {
            lock.lock()
            if outcome == nil, clock.now >= deadline { outcome = .timedOut(original) }
            if let outcome {
                lock.unlock()
                onWorkFinished()
                continuation.resume(returning: outcome)
                return
            }
            self.continuation = continuation
            self.onWorkFinished = onWorkFinished
            // Install both handles under the lock so cancellation cannot miss a just-starting task.
            work = Task.detached { [self] in
                let result: TranscriptRevision
                do {
                    try Task.checkCancellation()
                    result = try await operation()
                } catch {
                    result = .unavailable(original)
                }
                finish(result, enforcingDeadline: true)
            }
            timer = Task.detached { [self] in
                do { try await clock.sleep(until: deadline) }
                catch { return }
                finish(.timedOut(original))
            }
            lock.unlock()
        }

        func finish(_ value: TranscriptRevision, enforcingDeadline: Bool = false) {
            var delivery: (CheckedContinuation<TranscriptRevision, Never>, TranscriptRevision)?
            var cancelWork: Task<Void, Never>?
            var cancelTimer: Task<Void, Never>?
            lock.lock()
            // 审查修复：deadline/调用方取消定案路径（enforcingDeadline == false）
            // 此前把释放挂在「工作线程真正退出」之后（didDeliverCancellation）——
            // operation 忽略取消、永不返回时 reservation 永久占用，会话剩余
            // refine 全部 unavailable。结果一旦定案即释放槽位（挂起任务仍尽力
            // 取消，但释放不以其退出为前提）。
            let deadlineExpired = !enforcingDeadline
            if enforcingDeadline { workFinished = true }
            if outcome == nil {
                let result: TranscriptRevision
                if enforcingDeadline, clock.now >= deadline {
                    result = .timedOut(original)
                } else {
                    result = value.original.utf8.elementsEqual(original.utf8) ? value : .unavailable(original)
                }
                outcome = result
                if let continuation { delivery = (continuation, result) }
                if let work {
                    if !workFinished { cancellationFinished = false }
                    cancelWork = work
                }
                cancelTimer = timer
                continuation = nil
                work = nil
                timer = nil
            }
            if deadlineExpired {
                workFinished = true
                cancellationFinished = true
            }
            let release = takeReleaseIfFinished()
            lock.unlock()
            release?()
            if let delivery { delivery.0.resume(returning: delivery.1) }
            cancelTimer?.cancel()
            if let cancelWork {
                // Task.cancel runs arbitrary handlers synchronously; never run native handlers on the caller.
                Task.detached { [self] in
                    cancelWork.cancel()
                    didDeliverCancellation()
                }
            }
        }

        private func didDeliverCancellation() {
            lock.lock()
            cancellationFinished = true
            let release = takeReleaseIfFinished()
            lock.unlock()
            release?()
        }

        /// Called only while holding lock; the lease callback is consumed once.
        private func takeReleaseIfFinished() -> (@Sendable () -> Void)? {
            guard workFinished, cancellationFinished else { return nil }
            let release = onWorkFinished
            onWorkFinished = nil
            return release
        }
    }
}
