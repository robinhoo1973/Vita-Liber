import Foundation
import Domain

/// 启动自检事实快照（U-批 B2；架构席 A1/B2 定稿：不扩 `DatabaseBootPhase`）。
///
/// 发射语义（测试钉死）：
/// - **成功路径 2 次**：advisory 在 `prepareSync` 决策得出后、switch/抛出前；
///   final 在 `AppContainer.live` + `CatalogSlicesState`（facade）之后——
///   final 的 `committedKinds` 取 facade.availableKinds 真值（批 ③），行③以读面为准。
/// - **失败路径 1 次**：advisory（行③标签固定 advisory/未校验，即使 probe 曾
///   ready 也不得写 ready）；行①/②由 advisory + failure 推导，行④跳过。
/// - 每次启动尝试重置计数（重试=新尝试新快照，不得复用）。
///
/// 快照是行状态推导的唯一事实载体；其推导为纯函数（后续 `StartupSelfCheckRules`
/// 扩展），`DatabaseBootPhase` 只做进行态。
struct BootChecklistSnapshot: Sendable, Equatable {
    /// 患者主库探测事实（Domain 纯值）。
    let probe: DatabaseProbeSnapshot
    /// 启动决策（U-批 B3：行①/②由它经 `StartupSelfCheckRows` 纯函数推导）。
    let decision: DatabaseBootDecision?
    /// 决策诊断标签（`fresh/ready-v49/migrate-v48-to-v49/...`；诊断/日志用）。
    let decisionLabel: String
    /// 迁移总步数（`SchemaMigrations.pending(from:).count`；非 migrate 决策为 nil）。
    let plannedMigrationSteps: Int?
    /// 每片启动健康度（Q14=B 全量校验结果；typed enum）。批 ③ 起=open 后实测，
    /// advisory 恒空、final 取 `PreparedDatabase.sliceHealth`（不再复制 advisory）。
    let sliceHealth: [CatalogSliceKind: CatalogSliceBootHealth]
    /// 已提交读面的切片（源=`CatalogSliceReadFacade.availableKinds`；批 ③ 取代
    /// 旧布尔 `facadeCommitted`——布尔恒 true 掩盖「探测 ready 而读面未挂」假绿）。
    let committedKinds: Set<CatalogSliceKind>

    init(probe: DatabaseProbeSnapshot, decision: DatabaseBootDecision?,
         decisionLabel: String,
         plannedMigrationSteps: Int?, sliceHealth: [CatalogSliceKind: CatalogSliceBootHealth],
         committedKinds: Set<CatalogSliceKind> = []) {
        self.probe = probe
        self.decision = decision
        self.decisionLabel = decisionLabel
        self.plannedMigrationSteps = plannedMigrationSteps
        self.sliceHealth = sliceHealth
        self.committedKinds = committedKinds
    }

    /// 行③展示口径：读面未提交（失败/advisory）时不得宣称 ready。
    func displayHealth(for kind: CatalogSliceKind) -> CatalogSliceBootHealth {
        committedKinds.contains(kind) ? (sliceHealth[kind] ?? .missing) : .missing
    }
}
