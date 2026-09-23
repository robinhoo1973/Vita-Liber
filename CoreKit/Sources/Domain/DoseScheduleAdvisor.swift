import Foundation

/// FR9.19 服药时刻推荐（V4.04）：频率 → 默认时刻/间隔的**提案**（纯函数，Linux 可单测）。
///
/// 仅提案不落库：确认页/计划表单预选、用户逐项可改，确认后才写 `schedule_json`（BR-003/004 不变）。
/// 分布口径（业界服药 App 通行做法：在清醒窗 08:00–20:00 内均匀铺开，不跨睡眠时段）：
/// qd 08:00；bid 08:00/20:00（≈12 小时间隔）；tid 08:00/14:00/20:00；qid 08:00/12:00/16:00/20:00。
/// 「每 N 小时」→ `interval(everyMinutes: N×60)` 自 08:00 起（绝对时间推进交给调度引擎）。
/// 隔日一次 → `cycle(everyDays: 2, daysOn: 1)`。按需用药与餐时关系不在此推荐时刻（各有通道）。
public enum DoseScheduleAdvisor {
    /// 清醒窗（分钟制，含端点）：推荐时刻的铺开区间。
    public static let wakingStartMinutes = 8 * 60      // 08:00
    public static let wakingEndMinutes = 20 * 60       // 20:00

    /// 推荐提案：`basis` 为推荐依据（展示/审计用，如 "bid"/"interval8h"/"every2Days"）。
    public struct Proposal: Equatable, Sendable {
        public var schedule: MedicationSchedule
        public var basis: String
        public init(schedule: MedicationSchedule, basis: String) {
            self.schedule = schedule
            self.basis = basis
        }
    }

    /// 频率推荐：`intervalHours`（用户原文字面「每 N 小时」）优先于 `timesPerDay` 表。
    /// `isAsNeeded == true` → nil（按需用药不推荐时刻，FR9.19 边界）。
    /// `timesPerDay` 超出 1…4 → nil（不猜，交用户手填）。
    public static func advise(timesPerDay: Int?, intervalHours: Int? = nil,
                              isAsNeeded: Bool = false) -> Proposal? {
        if isAsNeeded { return nil }
        if let intervalHours, intervalHours > 0, intervalHours < 24 {
            return Proposal(schedule: .interval(everyMinutes: intervalHours * 60, start: "08:00"),
                            basis: "interval\(intervalHours)h")
        }
        switch timesPerDay {
        case 1: return Proposal(schedule: .fixed(times: evenlySpacedTimes(count: 1)), basis: "qd")
        case 2: return Proposal(schedule: .fixed(times: evenlySpacedTimes(count: 2)), basis: "bid")
        case 3: return Proposal(schedule: .fixed(times: evenlySpacedTimes(count: 3)), basis: "tid")
        case 4: return Proposal(schedule: .fixed(times: evenlySpacedTimes(count: 4)), basis: "qid")
        default: return nil
        }
    }

    /// 每隔 N 日给药（如「隔日一次」N=2）→ cycle 提案；N < 2 → nil。
    public static func adviseEveryNDays(_ n: Int, time: String = "08:00") -> Proposal? {
        guard n >= 2 else { return nil }
        return Proposal(schedule: .cycle(everyDays: n, daysOn: 1), basis: "every\(n)Days")
    }

    /// 清醒窗内均匀铺开 n 个时刻（"HH:mm"）。count ≤ 0 → 空；count 1 → 08:00。
    /// 结果如：2→08:00,20:00；3→08:00,14:00,20:00；4→08:00,12:00,16:00,20:00。
    public static func evenlySpacedTimes(count: Int) -> [String] {
        guard count >= 1 else { return [] }
        if count == 1 { return ["08:00"] }
        var out: [String] = []
        for index in 0..<count {
            let minutes = wakingStartMinutes
                + (wakingEndMinutes - wakingStartMinutes) * index / (count - 1)
            out.append(String(format: "%02d:%02d", minutes / 60, minutes % 60))
        }
        return out
    }
}
