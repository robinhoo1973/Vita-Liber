import Foundation

/// FR9.8.3 配药日历投影（V4.04 增补）：安全线剩余天数 → 预计用尽日 / 建议配药日。
///
/// 纯算术（剩余量 ÷ 计划日当量已在调用侧完成），**不构成用药建议**（BR-006）；
/// 展示口径同诚实性文案纪律（约值、不上报到小时）。误差取向与 ADR-009 一致：
/// **偏向更早**——剩余天数向上取整（宁可早提示，不装精确）。
public enum RefillProjection {
    /// 默认提前量（天）：建议配药日 = 用尽日 − leadTimeDays（可在 FR14.7 调整）。
    public static let defaultLeadTimeDays = 3

    public struct Result: Equatable, Sendable {
        public var depletionDate: Date
        public var suggestedRefillDate: Date
        /// 建议配药日已过（逾期）——供 UI 如实呈现（中性事实句式，不制造恐慌文案）。
        public var suggestedRefillPassed: Bool
        public init(depletionDate: Date, suggestedRefillDate: Date, suggestedRefillPassed: Bool) {
            self.depletionDate = depletionDate
            self.suggestedRefillDate = suggestedRefillDate
            self.suggestedRefillPassed = suggestedRefillPassed
        }
    }

    /// `relativeDays`：安全线剩余 ÷ 计划日当量（`inventorySummary` 既有口径；Double）。
    /// 负数/0 → 用尽日 = now（已耗尽/未知不虚构未来）。跨天用日历加法（时区/DST 安全）。
    public static func project(relativeDays: Double, leadTimeDays: Int = defaultLeadTimeDays,
                               now: Date, calendar: Calendar = .current) -> Result {
        let days = Int(max(0, relativeDays).rounded(.up))
        let depletion = calendar.date(byAdding: .day, value: days, to: now) ?? now
        let refill = calendar.date(byAdding: .day, value: -max(0, leadTimeDays), to: depletion) ?? depletion
        return Result(depletionDate: depletion,
                      suggestedRefillDate: refill,
                      suggestedRefillPassed: refill < now)
    }
}
