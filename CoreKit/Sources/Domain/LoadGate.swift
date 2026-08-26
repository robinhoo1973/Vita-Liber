import Foundation

/// R0-1 LoadGate：启动期一次性加载闸门（§4.4）——消除视图层重复 loadAll 的根机制
public actor LoadGate {
    public enum State: Sendable, Equatable { case idle, loading, ready }
    private var state: State = .idle
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}

    /// 首个调用者执行 load；并发调用挂起至完成；重复调用直接返回（幂等）
    public func enter(_ load: @Sendable () async throws -> Void) async rethrows {
        switch state {
        case .ready: return
        case .loading:
            await withCheckedContinuation { waiters.append($0) }
        case .idle:
            state = .loading
            defer {
                state = .ready
                waiters.forEach { $0.resume() }
                waiters.removeAll()
            }
            try await load()
        }
    }
    public var currentState: State { state }
}
