#if os(Linux)
import Foundation
import Domain

/// Linux 构建桩（CoreKit 在 Linux CI 上必须可编译可测）：
/// 恒可用、恒成功——门禁行为断言由 App 层注入 FakeGateUnlocker 承担。
public final class StubGateUnlocker: GateUnlocking, @unchecked Sendable {
    public init() {}

    public var isAvailable: Bool { true }

    public func authenticate(reason: String) async -> Bool { true }
}
#endif
