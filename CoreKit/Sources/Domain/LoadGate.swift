import Foundation

/// R0-1 LoadGate：启动期一次性加载闸门（§4.4）——消除视图层重复 loadAll 的根机制
public actor LoadGate {
    public enum State: Sendable, Equatable { case idle, loading, ready }
    private var state: State = .idle
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// 发起方 load 的失败结果（等待者醒后据此 rethrow——第六轮全仓审查修复：
    /// 原实现失败只 rethrow 给发起方，等待者如成功返回，迁移失败后
    /// 部分调用方误以为数据就绪）
    private var failure: (any Error)?
    public init() {}

    /// 首个调用者执行 load；并发调用挂起至完成；重复调用直接返回（幂等）。
    /// 失败语义（评审修正）：load 抛错 → 回到 .idle 并唤醒等待者，错误 rethrow 给发起方——
    /// 失败不得置 .ready（否则迁移失败后全 App 误以为数据就绪），也不得卡死 waiters。
    public func enter(_ load: @Sendable () async throws -> Void) async throws {
        switch state {
        case .ready: return
        case .loading:
            await withCheckedContinuation { waiters.append($0) }
            if let failure { throw failure }
        case .idle:
            state = .loading
            do {
                try await load()
                state = .ready
                failure = nil
                waiters.forEach { $0.resume() }
                waiters.removeAll()
            } catch {
                state = .idle
                failure = error
                waiters.forEach { $0.resume() }
                waiters.removeAll()
                throw error
            }
        }
    }
    public var currentState: State { state }
}
