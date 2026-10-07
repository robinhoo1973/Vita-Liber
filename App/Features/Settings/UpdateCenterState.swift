import Foundation
import Domain
import Perception

/// 统一更新中心 · 编排（2026-10-07 委员会架构席 §1.2 设计）。
///
/// 扇出并行 + **按域自结**（无 await-all、无统一完成裁决/统一 toast）；
/// 聚合格 busy 为**派生态**（本类零自有可变状态）；业务判定全部转交 Domain
/// `UpdateCenterRules`（本类零二次判定）。可用性**永不受通告态影响**（R2.6）。
@MainActor
@Perceptible
final class UpdateCenterState {
    private let advice: UpdateAdviceState
    private let chains: [UpdateAdviceDomain: any UpdateChainDriving]

    init(advice: UpdateAdviceState, chains: [UpdateAdviceDomain: any UpdateChainDriving]) {
        self.advice = advice
        self.chains = chains
    }

    /// 任一子链在途（通告读取 / 域检查）即 busy——纯派生，观察依赖落在子对象上。
    var isBusy: Bool {
        advice.isReading || chains.values.contains { $0.chainSummary == .checking }
    }

    /// 一次显式点按 = 并行触发通告读取与全部**可检查**域（域自持单飞原地守卫）。
    /// 更新/安装进行中的域跳过（不发请求——行内以 `.updating` 如实呈现）。
    func checkAll() {
        guard !isBusy else { return }
        advice.read()
        for chain in chains.values where chain.chainSummary != .updating {
            chain.check()
        }
    }

    /// 取消：通告读取 + 各域检查逐组件真中断（无在途者自守卫）。
    func cancelAll() {
        advice.cancel()
        for chain in chains.values { chain.cancelCheck() }
    }

    /// 单域呈现（Domain 纯函数唯一出口；未装配域 = `.unavailable`）。
    func presentation(for domain: UpdateAdviceDomain) -> UpdateCenterRowPresentation {
        UpdateCenterRules.rowPresentation(
            chain: chains[domain]?.chainSummary ?? .unavailable,
            advice: advice.rowState(domain))
    }
}
