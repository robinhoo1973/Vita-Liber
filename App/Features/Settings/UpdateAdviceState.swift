import Foundation
import Domain
import Infrastructure
import Perception

/// SP-64 通告区状态（README VL-INDEX 二维码；委员会 P3 设计，2026-10-07）。
///
/// R2.x 纪律在类型面：载荷态**永不改变交互可用性**（读取按钮任何态下可用，
/// R2.6）；读取是纯显式动作（零隐式联网）；provider 缺省 = 全域不可用
/// （fail-closed，同 checker 缺省语义）。
///
/// 2026-10-07 统一更新中心批：read 改「同步置位 + 存储 task」——编排
/// （UpdateCenterState.checkAll）的单飞/防抖依赖同步段完成置位，镜像
/// `MedicalCatalogUpdateCoordinator.check` 先例；新增 `cancel()`（真中断 +
/// 迟到结果丢弃——取消不得经 service 的 catch-all 归约出「通告暂不可用」假象）；
/// R11：outcome 已落定但域缺行 = `.unavailable`（不得回退成「尚未读取」假象）。
@MainActor
@Perceptible
final class UpdateAdviceState {
    private let provider: (any UpdateAdviceProviding)?
    private(set) var outcome: UpdateAdviceOutcome?
    private(set) var isReading = false
    /// 最近一次读取任务（取消后保留引用供 await；下次 read 覆盖）。
    private(set) var readTask: Task<Void, Never>?

    init(provider: (any UpdateAdviceProviding)?) {
        self.provider = provider
    }

    /// 单域行态；尚未读取 = nil（界面呈「尚未读取」，不与「不可用」混淆，R2.1/R2.3）。
    /// 读取已落定但该域缺行 = `.unavailable`（R11：已读过的通告不得伪装成未读）。
    func rowState(_ domain: UpdateAdviceDomain) -> UpdateAdviceRowState? {
        guard let outcome else { return nil }
        return outcome.rows[domain] ?? .unavailable
    }

    /// 显式读取（单飞；同步置位后入异步）。任何失败由 provider 归约为不可用态；
    /// 取消时丢弃迟到结果、保持既有状态（不产「暂不可用」假象）。
    func read() {
        guard !isReading else { return }
        guard let provider else {
            outcome = .unavailable()
            return
        }
        isReading = true
        readTask = Task { [weak self] in
            let result = await provider.read()
            guard let self, !Task.isCancelled else { return }
            self.outcome = result
            self.isReading = false
            self.readTask = nil
        }
    }

    /// 取消读取：真中断 + 迟到结果丢弃。取消后保持既有 outcome（首读取消 = 仍未读）。
    func cancel() {
        guard isReading else { return }
        readTask?.cancel()
        isReading = false
    }
}
