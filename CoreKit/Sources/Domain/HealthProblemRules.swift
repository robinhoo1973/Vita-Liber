import Foundation

/// 健康史条目的年份/病程纯规则（FR11.4，2026-10-23 业主：慢性病多久了）。
/// 年份解析与病程计算只有这一处实现——新建流、编辑流与列表展示共用，
/// 视图层不得再复制 `count == 4` 之类判定。
public enum HealthProblemRules {
    /// 四位年份，且落在 `1900...今年`；其他形态（"202"、"24"、"abcd"、
    /// 未来年份）一律 nil——调用方必须响亮拒绝，绝不猜语义。
    public static func parseYear(_ raw: String, now: Date = Date(),
                                 calendar: Calendar = .current) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 4, let year = Int(trimmed) else { return nil }
        let current = calendar.component(.year, from: now)
        guard year >= 1900, year <= current else { return nil }
        return year
    }

    /// 从登记年份到今年的整年数（今年登记 = 0，展示为「不足 1 年」）。
    /// 年份未知/非法/未来 → nil（展示层不显示病程，不编造）。
    public static func durationYears(since year: Int?, now: Date = Date(),
                                     calendar: Calendar = .current) -> Int? {
        guard let year else { return nil }
        let current = calendar.component(.year, from: now)
        guard year >= 1900, year <= current else { return nil }
        return current - year
    }
}
