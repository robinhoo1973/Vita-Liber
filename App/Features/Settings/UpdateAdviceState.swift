import Foundation
import Domain
import Infrastructure
import Perception

/// SP-64 通告区状态（README VL-INDEX 二维码；委员会 P3 设计，2026-10-07）。
///
/// R2.x 纪律在类型面：载荷态**永不改变交互可用性**（读取按钮任何态下可用，
/// R2.6）；读取是纯显式动作（零隐式联网）；provider 缺省 = 全域不可用
/// （fail-closed，同 checker 缺省语义）。
@MainActor
@Perceptible
final class UpdateAdviceState {
    private let provider: (any UpdateAdviceProviding)?
    private(set) var outcome: UpdateAdviceOutcome?
    private(set) var isReading = false

    init(provider: (any UpdateAdviceProviding)?) {
        self.provider = provider
    }

    /// 单域行态；尚未读取 = nil（界面呈「尚未读取」，不与「不可用」混淆，R2.1/R2.3）。
    func rowState(_ domain: UpdateAdviceDomain) -> UpdateAdviceRowState? {
        outcome?.rows[domain]
    }

    /// 显式读取（单飞；任何失败由 provider 归约为不可用态）。
    func read() async {
        guard !isReading else { return }
        guard let provider else {
            outcome = .unavailable()
            return
        }
        isReading = true
        defer { isReading = false }
        outcome = await provider.read()
    }
}
