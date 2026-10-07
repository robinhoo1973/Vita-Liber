import Foundation
import Domain

/// 统一更新中心 · 域链驱动端口（App 层横切；委员会架构席 §1.2，2026-10-07）。
///
/// 中心只经此协议触发/观察各域检查——域实现自持单飞与状态机；
/// `check`/`cancelCheck` 必须在 @MainActor 同步段完成置位（编排防抖依赖此纪律，
/// 镜像 `MedicalCatalogUpdateCoordinator.check` 先例）。
@MainActor
protocol UpdateChainDriving: AnyObject {
    /// 域链面聚合态（Domain 纯类型；中心主行输入）。
    var chainSummary: UpdateChainRowState { get }
    func check()
    func cancelCheck()
}

/// 医疗目录链一致性扩展：`check`/`cancelCheck` 由既有转发面提供（零改动）；
/// 更新/下载进行中优先呈 `.updating`（与 ASR 侧 chainSummary 同口径）。
extension MedicalCatalogState: UpdateChainDriving {
    var chainSummary: UpdateChainRowState {
        isUpdating ? .updating : UpdateCenterRules.chainState(from: remoteState)
    }
}

/// ASR 索引链一致性扩展：`check` 已具同名签名；`cancelCheck` 映射真中断
/// `cancel()`（迟到结果由状态机内 `Task.isCancelled` 守卫丢弃）。
/// CI 37580929178 实证：缺此遵从会让两处注入点 `[any UpdateChainDriving]`
/// 字典编译失败，而 App 目标在 Linux 零型检——修正时须连带扫同批注入点。
extension ASRIndexCheckState: UpdateChainDriving {
    func cancelCheck() { cancel() }
}
