import Foundation

/// 健康同步周期（2026-10-21 业主裁决）：间隔按电量友好档位选择。
///
/// Apple 的 `HKUpdateFrequency` 只有 immediate/hourly/daily/weekly——最短可靠
/// 后台投递是小时级；30 分钟不是 HealthKit 可保证的频率。这里的最小档为 1 小时，
/// 其余档位在小时投递之上由 App 自行节流（系统仍可能因电量/使用习惯延后）。
public enum HealthSyncInterval: Int, Sendable, CaseIterable, Codable {
    case hourly = 60
    case twoHours = 120
    case fourHours = 240
    case eightHours = 480
    case daily = 1_440

    public static let `default`: HealthSyncInterval = .fourHours

    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }

    /// 解析设置原始值；非法/缺失回落默认档（不把坏值解释成更频繁同步）。
    public static func resolved(_ raw: String?) -> HealthSyncInterval {
        guard let raw, let minutes = Int(raw), let value = Self(rawValue: minutes) else {
            return .default
        }
        return value
    }
}

/// 一个同步周期的持久状态：全部类别稳定才算一次完成。
public struct HealthSyncCycleState: Sendable, Equatable {
    public var startedAt: Date?
    public var completedAt: Date?
    /// 本周期已连续无新增达到稳定门槛的类别。
    public var stableKinds: Set<HealthDataKind>

    public init(startedAt: Date? = nil, completedAt: Date? = nil,
                stableKinds: Set<HealthDataKind> = []) {
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.stableKinds = stableKinds
    }

    public var isActive: Bool { startedAt != nil && completedAt == nil }
    public var isComplete: Bool { completedAt != nil }
    public var isInitial: Bool { startedAt == nil && completedAt == nil }
}

public enum HealthSyncCycleRules {
    /// 完成一次后至少等待所选间隔；未完成时下一唤醒继续。
    public static func isDue(lastCompletedAt: Date?, now: Date,
                             interval: HealthSyncInterval) -> Bool {
        guard let lastCompletedAt else { return true }
        return now.timeIntervalSince(lastCompletedAt) >= interval.seconds
    }

    public static func pendingKinds(_ stable: Set<HealthDataKind>,
                                    from kinds: [HealthDataKind] = HealthDataKind.allCases)
        -> [HealthDataKind] {
        kinds.filter { !stable.contains($0) }
    }

    public static func allStable(_ stable: Set<HealthDataKind>,
                                 from kinds: [HealthDataKind] = HealthDataKind.allCases) -> Bool {
        Set(kinds).isSubset(of: stable)
    }
}
