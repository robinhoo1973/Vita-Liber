import Foundation

/// FR16.1 首次回填分道（round2 H-N1 / 决策 Q5）：HKAnchoredObjectQuery 按 HealthKit 行序最旧优先
/// 且不可倒序，让「近一年先到」的唯一手段是把谓词限定在近一年；两道以样本 end 在 cutoff 处
/// 互补分割——recent = end >= cutoff（HealthKit 默认样本谓词左闭），history = end < cutoff
/// （`.strictEndDate` 右开）。两道各持独立游标（`hk_sync_anchor` 键 recent=`hk.v4`（降序首填游标）/history=`hk.v3`）。
public enum HealthFetchLane: String, Sendable, Codable, CaseIterable {
    case recent, history
}

public struct HealthFetchScope: Sendable, Hashable, Codable {
    /// 近一年 = 365 日历日（DayArithmetic，DST 纪律）
    public static let recentDays = 365
    public let lane: HealthFetchLane
    /// 固定于绑定时刻（connected_at − 365 日历日），不随 now 漂移——两道边界必须持久一致，
    /// 否则边界样本在两道间漂移会出现缝隙（漏样本）或双计。
    public let cutoff: Date

    public init(lane: HealthFetchLane, cutoff: Date) {
        self.lane = lane
        self.cutoff = cutoff
    }

    public static func cutoff(connectedAt: Date, calendar: Calendar) -> Date {
        DayArithmetic.offset(days: -recentDays, from: connectedAt, calendar: calendar)
    }

    /// 排空顺序即数组顺序：先 recent（近一年最新优先可见），空页后再 history。
    public static func scopes(connectedAt: Date, calendar: Calendar) -> [HealthFetchScope] {
        let boundary = cutoff(connectedAt: connectedAt, calendar: calendar)
        return [HealthFetchScope(lane: .recent, cutoff: boundary),
                HealthFetchScope(lane: .history, cutoff: boundary)]
    }

    /// 与 Infrastructure 的 HealthKit 谓词保持同一边界语义（HealthKitReaderPredicateTests 在 CI 实证）。
    public func matches(_ sample: HealthSampleReference) -> Bool {
        switch lane {
        case .recent: return sample.end >= cutoff
        case .history: return sample.end < cutoff
        }
    }
}
