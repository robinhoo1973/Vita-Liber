import Foundation

/// FR9.19 用药冲突提示（V4.04）：**纯排程事实**提示，不出医学结论（BR-006）。
///
/// ① 餐时窗互斥：同一时段（±30min 容差，与 FR9.17 同口径）内混有互斥餐时关系
///    （空腹/餐前族 vs 餐后族，均为处方转录值）→ 提示核对；
/// ② 与他药间距过近：两药计划时刻间隔 < 阈值 → 提示「是否需要错开」。
///    阈值经注入参数提供（生产 = GuidelineSource B 级 + 医学审核闸；
///    未过闸传 nil → 间距类提示整体不出现，仅转录处方原文的原则，业主 Q5=A）。
public enum DoseConflictRules {
    /// 时段聚合/冲突共用容差（与 FR9.17 ±30min 同口径）。
    public static let slotToleranceMinutes = 30

    public struct DoseRef: Equatable, Sendable {
        /// 计划/剂量标识（同 id 视为同一来源，不做间距自比较）。
        public var id: String
        /// 药名（展示用）。
        public var label: String
        public var dueAt: Date
        /// 餐时关系（既有词表：beforeBreakfast/afterDinner/fasting/…）。
        public var mealRelation: String?
        public init(id: String, label: String, dueAt: Date, mealRelation: String? = nil) {
            self.id = id; self.label = label; self.dueAt = dueAt; self.mealRelation = mealRelation
        }
    }

    public enum Conflict: Equatable, Sendable {
        /// 同窗内餐时关系互斥（空腹/餐前族与餐后族混合）——排程事实，非医学结论。
        case mealWindowMismatch(first: String, second: String, at: Date)
        /// 与另一计划间距低于阈值（阈值来自注入 provider；provider 无值时不会产生）。
        case spacingBelowThreshold(first: String, second: String, gapMinutes: Int, thresholdMinutes: Int)
    }

    /// 空腹/餐前族：`fasting` 或 `before*`（处方转录词表口径）。
    public static func isFastingRelation(_ meal: String?) -> Bool {
        guard let meal else { return false }
        return meal == "fasting" || meal.hasPrefix("before")
    }

    /// 餐后族：`after*`。
    public static func isPostMealRelation(_ meal: String?) -> Bool {
        guard let meal else { return false }
        return meal.hasPrefix("after")
    }

    /// 主入口：同日剂量集合 → 冲突列表（按时间升序两两比较；不落库、不改事实）。
    /// - spacingThresholdMinutes == nil → 间距类提示不出现（Q5=A：仅转录原则）。
    public static func conflicts(doses: [DoseRef], spacingThresholdMinutes: Int?) -> [Conflict] {
        let sorted = doses.sorted { $0.dueAt < $1.dueAt }
        var out: [Conflict] = []
        guard sorted.count >= 2 else { return out }
        for i in 0..<(sorted.count - 1) {
            for j in (i + 1)..<sorted.count {
                let a = sorted[i]
                let b = sorted[j]
                let gap = Int((b.dueAt.timeIntervalSince(a.dueAt) / 60).rounded())
                if gap <= slotToleranceMinutes {
                    let mismatch = (isFastingRelation(a.mealRelation) && isPostMealRelation(b.mealRelation))
                        || (isPostMealRelation(a.mealRelation) && isFastingRelation(b.mealRelation))
                    if mismatch {
                        out.append(.mealWindowMismatch(first: a.label, second: b.label, at: b.dueAt))
                    }
                }
                if let threshold = spacingThresholdMinutes, threshold > 0,
                   a.id != b.id, gap < threshold {
                    out.append(.spacingBelowThreshold(first: a.label, second: b.label,
                                                      gapMinutes: gap, thresholdMinutes: threshold))
                }
            }
        }
        return out
    }
}
