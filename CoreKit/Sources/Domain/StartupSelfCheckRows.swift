import Foundation

/// 启动自检行状态推导（U-批 B3，2026-10-28；纯 Domain，Linux 可测）。
///
/// 事实载体 = `BootChecklistSnapshot`（App 层）投影为 `StartupSelfCheckFacts`：
/// 行①本地档案文件 / 行②档案结构版本 / 行③医疗数据目录。
/// 行④（参考目录版本）由 App 层 `CatalogSlicesState.aggregate` 驱动（零隐式联网
/// 语义独立），不入本域。
///
/// 状态语义（与 UI 席 §3.3 五语义轴对齐）：
/// - `pending`：尚未开始（首帧前）；
/// - `running`：进行中（探测/建库/迁移/装配）；
/// - `passed`：该行证实成立；
/// - `warning`：非致命异常（必需片缺失但 facade 已提交 → 不影响使用）；
/// - `failed`：阻断进入（fail-closed 决策）；
/// - `skipped`：上游失败或未装配，本行未校验（advisory；失败行③恒此态）。
public enum StartupSelfCheckRowState: Sendable, Equatable {
    case pending
    case running
    case passed
    case warning
    case failed
    case skipped
}

/// 三行状态组合（行序固定：文件 → 结构 → 目录）。
public struct StartupSelfCheckRowStates: Sendable, Equatable {
    public let file: StartupSelfCheckRowState
    public let schema: StartupSelfCheckRowState
    public let catalog: StartupSelfCheckRowState

    public init(file: StartupSelfCheckRowState, schema: StartupSelfCheckRowState,
                catalog: StartupSelfCheckRowState) {
        self.file = file
        self.schema = schema
        self.catalog = catalog
    }
}

/// 行推导事实（`BootChecklistSnapshot` 的 Domain 投影）。
/// `decision == nil` 表示尚未得出启动决策；`isWorking` 表示启动门处于进行态；
/// `didFail` 表示启动门已抛错（B3 评审修复：失败卡在屏时行①②不得显示通过）。
public struct StartupSelfCheckFacts: Sendable, Equatable {
    public let probe: DatabaseProbeSnapshot
    public let decision: DatabaseBootDecision?
    public let health: [CatalogSliceKind: CatalogSliceBootHealth]
    public let facadeCommitted: Bool
    public let didFail: Bool
    public let isWorking: Bool

    public init(probe: DatabaseProbeSnapshot, decision: DatabaseBootDecision?,
                health: [CatalogSliceKind: CatalogSliceBootHealth],
                facadeCommitted: Bool, didFail: Bool = false, isWorking: Bool) {
        self.probe = probe
        self.decision = decision
        self.health = health
        self.facadeCommitted = facadeCommitted
        self.didFail = didFail
        self.isWorking = isWorking
    }
}

public enum StartupSelfCheckRows {
    /// 行①/②由启动决策唯一决定，行③以 facade 提交为准（B2 快照语义：
    /// 失败路径行③恒 advisory/未校验，即使探测曾 ready 也不得显示 ready）。
    public static func rows(_ facts: StartupSelfCheckFacts) -> StartupSelfCheckRowStates {
        let file: StartupSelfCheckRowState
        let schema: StartupSelfCheckRowState
        if let decision = facts.decision {
            switch decision {
            case .fresh:
                // 失败态（didFail）＝建库未成功：不得显示「已在本机建立档案」。
                file = facts.didFail ? .failed : (facts.isWorking ? .running : .passed)
                schema = facts.didFail ? .skipped : (facts.isWorking ? .running : .passed)
            case .ready:
                file = .passed
                schema = facts.didFail ? .failed : .passed
            case .migrate:
                file = .passed
                schema = facts.didFail ? .failed : (facts.isWorking ? .running : .passed)
            case .tooNew:
                file = .passed
                schema = .failed
            case .missingWithOriginals:
                file = .failed
                schema = .skipped
            case .corrupt(let reason):
                switch reason {
                case .missingRequiredTables:
                    // 文件可读；问题在结构层（表缺失=结构不可信）。
                    file = .passed
                    schema = .failed
                case .emptyFile, .badHeader, .unreadableVersion, .versionZeroWithTables:
                    file = .failed
                    schema = .skipped
                }
            }
        } else {
            file = facts.isWorking ? .running : .pending
            schema = facts.isWorking ? .running : .pending
        }

        let catalog: StartupSelfCheckRowState
        if !facts.facadeCommitted {
            catalog = facts.isWorking ? .running : .skipped
        } else if CatalogSliceBootPolicy.startupRequiredKinds.allSatisfy({
            facts.health[$0] == .ready
        }) {
            catalog = .passed
        } else {
            catalog = .warning
        }

        return StartupSelfCheckRowStates(file: file, schema: schema, catalog: catalog)
    }
}
