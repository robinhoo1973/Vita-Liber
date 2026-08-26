import Foundation

/// tech-spec §5.32 / FR1.3：防暴力破解节流 = 一等状态机。
/// 阶梯：5 次→30s / 再 5 次→2min / 此后→5min 封顶；成功即复位。
/// 计数跨重启保持（持久化由 Infrastructure 的 PinStateStore 实现，注入协议）。
public struct PinLockPolicy: Sendable, Equatable {
    public static let lockAfterFailures = 5
    public static let ladder: [TimeInterval] = [30, 120, 300]
    public static func lockout(for stage: Int) -> TimeInterval {
        ladder[min(max(stage, 0), ladder.count - 1)]
    }
    public init() {}
}

/// 持久化快照（Keychain 受保护条目语义；M1a 以文件/内存实现占位，iOS Keychain 归 L2 加固）
public struct PinLockSnapshot: Sendable, Equatable, Codable {
    public var consecutiveFailures: Int
    public var stage: Int              // 阶梯索引：每打满 lockAfterFailures 次递增一次
    public var lockedUntil: Date?
    public init(consecutiveFailures: Int = 0, stage: Int = 0, lockedUntil: Date? = nil) {
        self.consecutiveFailures = consecutiveFailures
        self.stage = stage
        self.lockedUntil = lockedUntil
    }
}

/// 状态持久化端口（Protocols 语义：Domain 不 import 具体存储）
public protocol PinLockPersisting: Sendable {
    func load() throws -> PinLockSnapshot
    func save(_ snapshot: PinLockSnapshot) throws
}

public actor PinLockStateMachine {
    private var failures: Int
    private var stage: Int
    private var lockedUntil: Date?
    private let storage: any PinLockPersisting
    private let now: @Sendable () -> Date

    public init(storage: any PinLockPersisting, now: @escaping @Sendable () -> Date = { Date() }) async throws {
        self.storage = storage
        self.now = now
        // 读取失败（无历史记录）→ 全新快照；不用 try?（tech-spec §7 红线）
        let loaded: PinLockSnapshot
        do { loaded = try storage.load() } catch { loaded = PinLockSnapshot() }
        // 持久化中的过期锁定在读取时自然解除
        self.failures = loaded.consecutiveFailures
        self.stage = loaded.stage
        self.lockedUntil = (loaded.lockedUntil.map { $0 > now() } ?? false) ? loaded.lockedUntil : nil
    }

    /// 失败计数 +1；打满阶梯则进入锁定，返回锁定时长（秒）；未打满返回 0
    public func recordFailure() throws -> TimeInterval {
        failures += 1
        if failures >= PinLockPolicy.lockAfterFailures {
            let lockout = PinLockPolicy.lockout(for: stage)
            lockedUntil = now().addingTimeInterval(lockout)
            failures = 0
            stage = min(stage + 1, PinLockPolicy.ladder.count - 1)
            try persist()
            return lockout
        }
        try persist()
        return 0
    }

    /// 成功即复位（防攻击者刷爆计数造成 DoS）
    public func recordSuccess() throws {
        failures = 0
        stage = 0
        lockedUntil = nil
        try persist()
    }

    public var isLocked: Bool { lockedUntil.map { $0 > now() } ?? false }
    public var remainingLockSeconds: TimeInterval {
        guard let until = lockedUntil else { return 0 }
        return max(0, until.timeIntervalSince(now()))
    }
    public var consecutiveFailures: Int { failures }

    public func snapshot() -> PinLockSnapshot {
        PinLockSnapshot(consecutiveFailures: failures, stage: stage, lockedUntil: lockedUntil)
    }

    private func persist() throws {
        try storage.save(snapshot())
    }
}

/// 测试用内存实现（Linux 单测主力）
public final class InMemoryPinLockStore: PinLockPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: PinLockSnapshot?
    public init() {}
    public func load() throws -> PinLockSnapshot { lock.lock(); defer { lock.unlock() }; return snapshot ?? PinLockSnapshot() }
    public func save(_ s: PinLockSnapshot) throws { lock.lock(); defer { lock.unlock() }; snapshot = s }
}
