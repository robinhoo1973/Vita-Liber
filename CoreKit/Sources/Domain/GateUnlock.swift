import Foundation

/// 门禁解锁端口（FR1.1 · V3.22 修订：系统设备所有者认证，应用内无 PIN）。
/// 生产实现 = Infrastructure/LocalAuthGateUnlocker（`.deviceOwnerAuthentication`，
/// 一次覆盖 Face ID / Touch ID / 设备密码兜底；失败节流由系统处理）；
/// 单测 / UI 测试注入假实现（Linux 构建注入 StubGateUnlocker）。
public protocol GateUnlocking: Sendable {
    /// 预检可用性（canEvaluatePolicy）——只用于 UI 提示，不构成门禁判定
    var isAvailable: Bool { get }
    /// 触发系统认证浮层；成功返回 true。取消 / 失败 / 不可用 → false
    func authenticate(reason: String) async -> Bool
}
