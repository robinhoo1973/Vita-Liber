import Foundation

/// Apple 健康导入范围（业主 2026-10-20 裁决：导入界面由用户选择）。
///
/// 三个档位只影响 **history 道**的下界；recent 道恒为连接时刻前 365 天：
/// - oneYear：history 为空（recent 已覆盖）；
/// - fiveYears：覆盖 [connectedAt − 5×365d, connectedAt − 365d)；
/// - all：覆盖连接时刻前的全部可读历史。
///
/// 缩小范围**不删除**已导入行；扩大范围只补新区间。深度变化会改变 history
/// 谓词，因此锚点键必须携带深度（见 `HealthImportStore.anchorKey`）。
public enum HealthHistoryDepth: String, Codable, Sendable, CaseIterable, Hashable {
    case oneYear, fiveYears, all

    /// history 道下界相对连接时刻的天数；nil = 无下界（全部历史）。
    public var days: Int? {
        switch self {
        case .oneYear: return 365
        case .fiveYears: return 1_825
        case .all: return nil
        }
    }
}

/// 单类型初始导入完成态（持久化在 `hk_import_completion`）。
///
/// “完成”只表示**所选范围**已排空且无 pending/deferred/failed；
/// 不表示读取授权完整（读取权限对 App 不可观察），也不表示未来不会新增数据。
public struct HealthKindCompletion: Sendable, Equatable, Codable {
    public var recentCompletedAt: Date?
    public var historyCompletedAt: Date?
    /// history 道已覆盖的深度；nil = 未完成或未指定。
    public var historyDepth: HealthHistoryDepth?
    /// HealthKit 明确报告该类型投递被阻断（权限未定/被拒）。阻断类型不标完成；
    /// 授权后续恢复时必须清该类型的锚点与完成态（见 HealthImportStore.resetKind）。
    public var blocked: Bool

    public init(recentCompletedAt: Date? = nil, historyCompletedAt: Date? = nil,
                historyDepth: HealthHistoryDepth? = nil, blocked: Bool = false) {
        self.recentCompletedAt = recentCompletedAt
        self.historyCompletedAt = historyCompletedAt
        self.historyDepth = historyDepth
        self.blocked = blocked
    }
}

/// 初始导入计划 + 完成事实。纯值，Domain 可测；持久化形态见 v36。
public struct HealthImportPlan: Sendable, Equatable, Codable {
    public var depth: HealthHistoryDepth
    public var selectedAt: Date
    /// key = `HealthDataKind.rawValue`
    public var completions: [String: HealthKindCompletion]
    /// 全部类型完成所选范围的时刻；nil = 初始导入未完成。
    public var initialCompletedAt: Date?

    public init(depth: HealthHistoryDepth, selectedAt: Date,
                completions: [String: HealthKindCompletion] = [:],
                initialCompletedAt: Date? = nil) {
        self.depth = depth
        self.selectedAt = selectedAt
        self.completions = completions
        self.initialCompletedAt = initialCompletedAt
    }

    public func completion(_ kind: HealthDataKind) -> HealthKindCompletion {
        completions[kind.rawValue] ?? HealthKindCompletion()
    }

    /// 已完成 depth 是否覆盖当前所选深度。
    /// - all 只能由 all 覆盖；
    /// - 有限深度可由同等或更大深度覆盖。
    public func covers(_ kind: HealthDataKind, depth: HealthHistoryDepth) -> Bool {
        let done = completion(kind)
        guard done.recentCompletedAt != nil, !done.blocked,
              let covered = done.historyDepth else { return false }
        switch depth {
        case .oneYear:
            return covered.days.map { $0 >= 365 } ?? true
        case .fiveYears:
            return covered.days.map { $0 >= 1_825 } ?? true
        case .all:
            return covered == .all
        }
    }

    public func remainingKinds(depth: HealthHistoryDepth) -> [HealthDataKind] {
        HealthDataKind.allCases.filter { !covers($0, depth: depth) }
    }

    /// 导入模式只由“完成事实”决定（业主 2026-10-20：已成功完整导入 → 只更新缺失部分）。
    /// 完成后的新数据/新删除是增量工作，不再是初始回填；初始页在途时该类型必然
    /// 未覆盖所选深度（`laneComplete` 才写完成），仍走 `.initialBackfill`。
    public func mode(depth: HealthHistoryDepth) -> HealthImportMode {
        let remaining = remainingKinds(depth: depth)
        return remaining.isEmpty ? .incremental : .initialBackfill(remaining: remaining)
    }
}

/// 后台/前台同步模式（业主 2026-10-20 裁决）：
/// - initialBackfill：初始导入未完成。激活即从断点续；pending 优先，两道轮转。
/// - incremental：已完成所选范围。只做锚点增量与缺失部分（含后补旧日期样本/墓碑），
///   不重扫历史。
public enum HealthImportMode: Sendable, Equatable {
    case initialBackfill(remaining: [HealthDataKind])
    case incremental

    public var isInitial: Bool {
        if case .initialBackfill = self { return true }
        return false
    }

    public var remainingKinds: [HealthDataKind] {
        if case .initialBackfill(let kinds) = self { return kinds }
        return []
    }
}
