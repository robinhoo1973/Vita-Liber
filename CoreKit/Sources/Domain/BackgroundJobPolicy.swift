import Foundation

/// 后台作业描述（round5 Q2，2026-09-20）：`BackgroundWorkScheduler`（Infrastructure）注册/提交的纯值。
/// iOS 没有守护进程——后台执行权只来自 OS 原语：`BGAppRefreshTask`（30 秒级、保持内容新鲜）、`BGProcessingTask`
/// （分钟级、设备空闲/充电时，实测 ≈5 分钟上限）、iOS 26 `BGContinuedProcessingTask`（用户动作发起、切后台续跑）、
/// 后台 `URLSession`、HealthKit 后台投递。本类型把「作业需要哪种原语与条件」表达为数据，作业本体只实现 `run(until:)`。
public struct BackgroundJobDescriptor: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 短任务（≈30s）：增量对账、锚点探测。
        case refresh
        /// 长任务（分钟级）：回填排空、解压校验、索引重建。
        case processing(requiresNetwork: Bool, requiresExternalPower: Bool)

        public var requiresNetwork: Bool { if case .processing(let n, _) = self { return n } else { return false } }
        public var requiresExternalPower: Bool { if case .processing(_, let p) = self { return p } else { return false } }
        public var isProcessing: Bool { if case .processing = self { return true } else { return false } }
    }

    /// `BGTaskSchedulerPermittedIdentifiers` 登记的标识符。
    public let identifier: String
    public let kind: Kind
    /// 两次运行的最小间隔（秒）——重排时 `earliestBeginDate = now + minimumInterval`；系统只保证不早于，不保证准时。
    public let minimumInterval: TimeInterval

    public init(identifier: String, kind: Kind, minimumInterval: TimeInterval) {
        self.identifier = identifier; self.kind = kind; self.minimumInterval = minimumInterval
    }

    public func earliestBeginDate(from now: Date) -> Date { now.addingTimeInterval(minimumInterval) }
}

/// 后台作业预算策略（纯函数）。
public enum BackgroundJobPolicy {
    /// 到期前留给「落盘 + 回报 setTaskCompleted」的余量（秒）。
    public static let completionMarginSeconds: Int64 = 10
    /// 系统未给到期信息时的保守默认（`BGProcessingTask` 社区实测 ≈295s；取 4 分钟）。
    public static let defaultProcessingBudget: Duration = .seconds(240)
    /// `BGAppRefreshTask` 类预算（Apple：约 30 秒）。
    public static let refreshBudget: Duration = .seconds(20)

    /// 作业可用时长 = 到期 − 现在 − 完成余量（不为负）；无到期 → 默认处理预算。
    public static func runBudget(now: Date, expiresAt: Date?) -> Duration {
        guard let expiresAt else { return defaultProcessingBudget }
        let seconds = Int64(expiresAt.timeIntervalSince(now).rounded(.down)) - completionMarginSeconds
        return .seconds(max(0, seconds))
    }
}

/// HealthKit 回填专用策略（round5 Q2）：此前后台每次唤醒每类只排 1 页（500 样本 + 32 窗），一年心率需数百次唤醒；
/// 本策略决定「何时申请一次分钟级处理任务」与「一次处理任务跑多少轮」。
public enum HealthSyncBacklogPolicy {
    /// 一次处理任务的轮数上限（每轮 = 每类 1 页 + ≤32 窗重算；经验 ≈1.5s/轮）。
    public static let roundsCap = 200
    /// 每轮经验时长（秒），用于把预算换算成轮数。
    public static let secondsPerRound = 1.5
    /// 回前台轻量对账轮数（此前 1；有界但不再「每次回前台只前进一页」）。
    public static let foregroundActiveRounds = 3

    /// 有剩余窗口或仍有更多页 → 值得申请处理任务；一无所知（nil）且无更多 → 不申请。
    public static func shouldRequestProcessing(remainingWindows: Int?, hasMore: Bool) -> Bool {
        hasMore || (remainingWindows ?? 0) > 0
    }

    /// 预算 → 轮数（至少 1、不超上限）。
    public static func maxRounds(for budget: Duration) -> Int {
        let seconds = Double(budget.components.seconds) + Double(budget.components.attoseconds) / 1e18
        return min(roundsCap, max(1, Int(seconds / secondsPerRound)))
    }
}
