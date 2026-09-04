#if !os(Linux)
import Foundation
import LocalAuthentication
import Domain

/// 门禁系统适配器（FR1.1 · V3.22）：`.deviceOwnerAuthentication` 让系统统一处理
/// 面容 / 指纹 / 设备密码三通道与失败节流（biometryLockout 后系统引导设备密码），
/// 应用侧零节流逻辑。每次调用新建 LAContext——复用旧 context 会携带取消/锁定
/// 残留状态，导致后续认证静默失败（返回 -4/LAError.notInteractive 类错误）。
public final class LocalAuthGateUnlocker: GateUnlocking, @unchecked Sendable {
    public init() {}

    public var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    public func authenticate(reason: String) async -> Bool {
        do {
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                                                        localizedReason: reason)
        } catch {
            return false   // 用户取消 / 连续失败锁定 / 未设密码 → UI 提供重试
        }
    }
}
#endif
