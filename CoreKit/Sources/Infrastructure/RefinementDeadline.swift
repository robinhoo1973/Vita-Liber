import Foundation
import Domain

// 2026-09-19 结构轮：从 Protocols/TextRefining.swift 迁至 Infrastructure——
// 生产级并发原语（单飞槽位 + 截止投递），协议层只留纯接口；唯一生产消费方
// LocalTranscriptRefiner 同在本层，测试 RefinementDeadlineTests 已导入 Infrastructure。

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
            // 槽位释放纪律（tech-spec V3.87）：「非合作原生工作保留单飞槽而
            // 不无限创建」——FR17.18 单飞保证以槽位保留为前提，deadline/调用方
            // 取消只定案「给调用者的结果」，槽位必须等到工作线程与取消投递
            // 双双退出才释放（takeReleaseIfFinished 双标志）。若在定案瞬间
            // 释放，忽略取消的原生调用未退出时即会接纳第二个并发代次，单飞
            // 失效。2026-09-10 曾误改（定案即释放），门禁 SU-M15-VOICE 红，
            // 按规格回退。
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
                if !workFinished, let work {
                    cancellationFinished = false
                    cancelWork = work
                }
                cancelTimer = timer
                continuation = nil
                work = nil
                timer = nil
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
