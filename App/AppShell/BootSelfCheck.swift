import Foundation
import Domain

/// 启动自检事实快照（U-批 B2；架构席 A1/B2 定稿：不扩 `DatabaseBootPhase`）。
///
/// 发射语义（测试钉死）：
/// - **成功路径 2 次**：advisory 在 `prepareSync` 决策得出后、switch/抛出前；
///   final 在 `AppContainer.live` + `CatalogSlicesState`（facade）之后——
///   final 的 `facadeCommitted == true`，行③以 facade 为准。
/// - **失败路径 1 次**：advisory（行③标签固定 advisory/未校验，即使 probe 曾
///   ready 也不得写 ready）；行①/②由 advisory + failure 推导，行④跳过。
/// - 每次启动尝试重置计数（重试=新尝试新快照，不得复用）。
///
/// 快照是行状态推导的唯一事实载体；其推导为纯函数（后续 `StartupSelfCheckRules`
/// 扩展），`DatabaseBootPhase` 只做进行态。
struct BootChecklistSnapshot: Sendable, Equatable {
    /// 患者主库探测事实（Domain 纯值）。
    let probe: DatabaseProbeSnapshot
    /// 决策诊断标签（`fresh/ready-v49/migrate-v48-to-v49/...`；行文案派生用）。
    let decisionLabel: String
    /// 迁移总步数（`SchemaMigrations.pending(from:).count`；非 migrate 决策为 nil）。
    let plannedMigrationSteps: Int?
    /// 每片启动健康度（Q14=B 全量校验结果；typed enum）。
    let sliceHealth: [CatalogSliceKind: CatalogSliceBootHealth]
    /// 是否已装配 facade（final 快照 true；advisory 恒 false）。
    let facadeCommitted: Bool

    init(probe: DatabaseProbeSnapshot, decisionLabel: String,
         plannedMigrationSteps: Int?, sliceHealth: [CatalogSliceKind: CatalogSliceBootHealth],
         facadeCommitted: Bool) {
        self.probe = probe
        self.decisionLabel = decisionLabel
        self.plannedMigrationSteps = plannedMigrationSteps
        self.sliceHealth = sliceHealth
        self.facadeCommitted = facadeCommitted
    }

    /// 行③展示口径：facade 未装配（失败/advisory）时不得宣称 ready。
    func displayHealth(for kind: CatalogSliceKind) -> CatalogSliceBootHealth {
        facadeCommitted ? (sliceHealth[kind] ?? .missing) : .missing
    }
}
