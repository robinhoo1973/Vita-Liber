import Foundation
import Domain

/// A timeout returns to the caller without freeing the single native generation slot prematurely.
final class UnderstandingDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private func acquire() -> Bool { lock.withLock { guard !busy else { return false }; busy = true; return true } }
    private func release() { lock.withLock { busy = false } }

    func run(timeout: Duration, operation: @escaping @Sendable () async throws -> UnderstandingResult) async -> UnderstandingResult? {
        guard !Task.isCancelled, acquire() else { return nil }
        let result = Delivery()
        let work = Task.detached { [self] in
            let value: UnderstandingResult?
            do { try Task.checkCancellation(); value = try await operation() }
            catch { value = nil }
            result.complete(value)
            release()
        }
        let timer = Task.detached {
            do { try await Task.sleep(for: timeout); result.complete(nil) }
            catch { /* 正常完成后取消timer */ }
        }
        let value = await withTaskCancellationHandler {
            await withCheckedContinuation { result.install($0) }
        } onCancel: {
            // Don't invoke arbitrary native cancellation handlers on the UI thread.
            result.complete(nil)
        }
        timer.cancel()
        // Native work may not cooperate; the slot remains busy until the task exits.
        // Leaving its bounded single request to finish avoids a synchronous cancellation-handler stall.
        withExtendedLifetime(work) {}
        return value
    }

    private final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var value: UnderstandingResult?
        private var continuation: CheckedContinuation<UnderstandingResult?, Never>?
        func install(_ next: CheckedContinuation<UnderstandingResult?, Never>) {
            lock.lock()
            if finished { let value = value; lock.unlock(); next.resume(returning: value) }
            else { continuation = next; lock.unlock() }
        }
        func complete(_ value: UnderstandingResult?) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true; self.value = value
            let next = continuation; continuation = nil
            lock.unlock()
            next?.resume(returning: value)
        }
    }
}
