import Foundation

/// FR9.17 服药时段聚合：查询层/视图层能力，不改动 dose_log 与扣减矩阵。
/// 按 (patientId, mealRelation, ±30min 容差) 分组；时段级单条通知以时段代表时刻发出。
/// dose 用户动作（FR9.7）：送达 ≠ 已服（BR-004）——只有显式确认才计扣减；
/// 「跳过/忘记」只写动作，永不推断病因。
public enum DoseUserAction: String, Sendable, Equatable, Codable {
    case taken, snoozed, skipped, missed, discomfort
}

/// 剂量记录 = 调度剂量 + 用户动作 + 药品定义投影（dose_log 行语义的查询投影）
public struct DoseRecord: Sendable, Equatable {
    public var dose: ScheduledDose
    public var action: DoseUserAction?
    public var medicationName: String?
    public var spec: String?
    public var unitKind: String?
    public init(dose: ScheduledDose, action: DoseUserAction? = nil,
                medicationName: String? = nil, spec: String? = nil, unitKind: String? = nil) {
        self.dose = dose; self.action = action
        self.medicationName = medicationName; self.spec = spec; self.unitKind = unitKind
    }
    /// 卡片行标签：「药名 规格 · 剂量单位」（评审修正：多药同卡可区分）
    public var displayLabel: String {
        var parts = [medicationName, spec].compactMap { $0 }.filter { !$0.isEmpty }
        if parts.isEmpty { parts = ["未命名药品"] }
        let doseText = dose.doseUnits == dose.doseUnits.rounded()
            ? "\(Int(dose.doseUnits)) \(unitKind ?? "单位")"
            : "\(dose.doseUnits) \(unitKind ?? "单位")"
        return parts.joined(separator: " ") + " · " + doseText
    }
}

public struct DoseSlot: Sendable, Equatable, Identifiable {
    public var id: String                    // 时段锚：日期+餐时关系
    public var anchorTime: Date
    public var mealRelation: String?
    public var records: [DoseRecord]
    public init(id: String, anchorTime: Date, mealRelation: String?, records: [DoseRecord]) {
        self.id = id; self.anchorTime = anchorTime; self.mealRelation = mealRelation; self.records = records
    }
    public var allTaken: Bool { !records.isEmpty && records.allSatisfy { $0.action == .taken } }
    public var anyPending: Bool { records.contains { $0.action == nil } }
}

public struct DoseSlotGrouping {
    public static let tolerance: TimeInterval = 30 * 60   // ±30min

    /// 餐时默认时刻（分钟表；锚点 = 当日 startOfDay + 分钟）
    static let mealMinutes: [String: Int] = [
        "beforeBreakfast": 7 * 60 + 30, "afterBreakfast": 8 * 60 + 30,
        "beforeLunch": 11 * 60 + 30, "afterLunch": 12 * 60 + 30,
        "beforeDinner": 17 * 60 + 30, "afterDinner": 19 * 60 + 30,
    ]

    /// 时段聚合（FR9.17）：
    /// - 餐时剂量锚定「餐时默认时刻」（不是首剂时刻——否则 ±30min 窗口随
    ///   首剂漂移，同一餐的 15min 前/后剂被错误拆分）；
    /// - 无餐时关系（fixed 类）做传递聚类：与时段内任一剂量相距 ≤30min 即并入。
    public static func group(_ records: [DoseRecord], calendar: Calendar = .current) -> [DoseSlot] {
        let sorted = records.sorted { $0.dose.dueAt < $1.dose.dueAt }
        var slots: [DoseSlot] = []
        for r in sorted {
            let d = r.dose
            if let meal = d.mealRelation {
                let anchor = mealAnchor(for: d.dueAt, relation: meal, calendar: calendar)
                // 同一餐时锚点 + 距锚 ≤30min 才同段；超容差的自定义时刻另起一段
                if let i = slots.firstIndex(where: { slot in
                    slot.mealRelation == meal && slot.anchorTime == anchor
                        && abs(d.dueAt.timeIntervalSince(anchor)) <= tolerance
                }) {
                    slots[i].records.append(r)
                } else {
                    slots.append(DoseSlot(id: "\(Int(anchor.timeIntervalSince1970))-\(meal)",
                                          anchorTime: anchor, mealRelation: meal, records: [r]))
                }
            } else {
                if let i = slots.firstIndex(where: { slot in
                    slot.mealRelation == nil
                        && slot.records.contains { abs(d.dueAt.timeIntervalSince($0.dose.dueAt)) <= tolerance }
                }) {
                    slots[i].records.append(r)
                } else {
                    slots.append(DoseSlot(id: "fixed-\(Int(d.dueAt.timeIntervalSince1970))",
                                          anchorTime: d.dueAt, mealRelation: nil, records: [r]))
                }
            }
        }
        return slots
    }

    static func mealAnchor(for date: Date, relation: String, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        let minutes = mealMinutes[relation] ?? 8 * 60 + 30
        return start.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// 单剂量的时段归属 id（通知 id = "slot-\(slotId)"；对账与稍后取消共用）
    public static func slotId(for record: DoseRecord, calendar: Calendar = .current) -> String? {
        group([record], calendar: calendar).first?.id
    }
}

/// FR9.8 双轨扣减（ADR-009）：
/// 安全线（plan track，计划驱动，告警偏早=safe-side bias，不可协商）与
/// 确认线（confirm track，仅用户确认「服了」驱动）严格分离。
/// 误差方向强制偏向提前告警：计划轨只按计划扣，确认轨只按事实扣，
/// 两者差异进入月报的纯事实句式（「计划 30 次/确认 21 次」），不做评分。
public struct DualTrackInventory: Sendable, Equatable, Codable {
    public var lotId: UUID
    public var totalUnits: Double
    public var remainingPlanUnits: Double      // 安全线
    public var remainingConfirmedUnits: Double // 确认线
    public var unitKind: String
    public var expireAt: Date?
    public var status: String                  // active/depleted/expired/discarded

    public init(lotId: UUID, totalUnits: Double, unitKind: String, expireAt: Date? = nil) {
        self.lotId = lotId
        self.totalUnits = totalUnits
        self.remainingPlanUnits = totalUnits
        self.remainingConfirmedUnits = totalUnits
        self.unitKind = unitKind
        self.expireAt = expireAt
        self.status = "active"
    }
}

public enum InventoryRules {
    /// 安全线扣减（计划轨）：计划按天推进，无论动作如何都要消耗
    public static func deductPlan(_ inv: DualTrackInventory, units: Double) -> DualTrackInventory {
        var v = inv
        v.remainingPlanUnits = max(0, v.remainingPlanUnits - units)
        return v
    }

    /// 确认线扣减（事实轨）：仅「服了」动作扣（BR-004）；跳过/忘记/不适均不扣确认线
    public static func deductConfirmed(_ inv: DualTrackInventory, units: Double) -> DualTrackInventory {
        var v = inv
        v.remainingConfirmedUnits = max(0, v.remainingConfirmedUnits - units)
        return v
    }

    /// FR9.8.2 扣减矩阵（评审修正：原实现只扣确认线，把违规格写绿）：
    /// - taken：两线各扣（计划轨消耗 + 事实轨消耗）
    /// - skipped/missed/discomfort：仅计划轨扣（计划已过，事实线不动）
    /// - snoozed：两线都不扣（临时延后，非终态动作）
    public static func applyResolution(_ inv: DualTrackInventory, units: Double, action: DoseUserAction) -> DualTrackInventory {
        switch action {
        case .snoozed:
            return inv
        case .taken:
            return deductConfirmed(deductPlan(inv, units: units), units: units)
        default:
            return deductPlan(inv, units: units)
        }
    }

    /// 续药告警（FR9.8.3）：安全线余量 ≤7 天当量 → 需告警（偏早）
    public static func refillAlertNeeded(_ inv: DualTrackInventory, dailyPlanUnits: Double, at date: Date) -> Bool {
        guard dailyPlanUnits > 0 else { return false }
        if let e = inv.expireAt, e < date { return true }   // 过期即告警
        let daysLeft = inv.remainingPlanUnits / dailyPlanUnits
        return daysLeft <= 7
    }

    /// 批次分配 FEFO（FR9.14）：先到期先出；到期日相同按余量降序
    public static func fefoOrder(_ lots: [DualTrackInventory]) -> [DualTrackInventory] {
        lots.sorted {
            let a = $0.expireAt ?? .distantFuture
            let b = $1.expireAt ?? .distantFuture
            if a != b { return a < b }
            return $0.remainingConfirmedUnits > $1.remainingConfirmedUnits
        }
    }

    /// 扣减矩阵单步（FR9.8.2）：确认「服了 n 单位」→ 按 FEFO 从各批扣确认线；
    /// 返回每批实扣量。跳过/忘记/不适 → 零扣减（纯事实）。
    public static func allocateConfirmed(lots: [DualTrackInventory], units: Double) -> (updated: [DualTrackInventory], allocations: [(lotId: UUID, units: Double)]) {
        var remaining = units
        var updated = lots
        var allocations: [(UUID, Double)] = []
        // 按 FEFO 序逐个取批（不可迭代排序副本的 indices——那会把
        // 「排序后的序号」当成原数组下标，扣错批次）
        for sortedLot in fefoOrder(updated) {
            guard remaining > 0 else { break }
            guard sortedLot.status == "active",
                  let i = updated.firstIndex(where: { $0.lotId == sortedLot.lotId }) else { continue }
            let lot = updated[i]
            let take = min(lot.remainingConfirmedUnits, remaining)
            if take > 0 {
                updated[i] = deductConfirmed(lot, units: take)
                allocations.append((lot.lotId, take))
                remaining -= take
            }
        }
        return (updated, allocations)
    }
}
