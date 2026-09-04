import Foundation
import Domain

/// 门禁测试替身（App 层注入，同 FakeOcrProvider 纪律：生产代码无 -uitest 分支，
/// 启动参数只在组合根/AppState init 消费）。XCUITest 无法自动化 Face ID——
/// SEC 用例经 -uitest-gate-stub-success / -uitest-gate-stub-fail 注入确定性结果。
final class FakeGateUnlocker: GateUnlocking, @unchecked Sendable {
    var result: Bool
    init(result: Bool = true) { self.result = result }
    var isAvailable: Bool { true }
    func authenticate(reason: String) async -> Bool { result }
}
