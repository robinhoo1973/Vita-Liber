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

    /// 餐时默认时刻（分钟表；锚点 = 当日 startOfDay + 分钟）。
    ///
    /// 评审修正（单一事实源）：此表此前与 `DoseScheduleEngine.mealDefaultTime`
    /// 各自硬编码一份且**回退值不同**（此处 08:30 / 引擎 08:00）——同一餐时关系
    /// 在「生成剂量」与「聚合锚点」两处取到不同时刻，±30min 窗口随之错位。
    /// 现改为从引擎字符串解析派生：锚点恒等于调度引擎产出的默认时刻，改引擎即改锚点。
    static func mealMinutes(for relation: String) -> Int {
        let time = DoseScheduleEngine.mealDefaultTime(relation)
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 8 * 60 + 30 }   // 引擎输出恒为 HH:mm，兜底不可达
        return parts[0] * 60 + parts[1]
    }

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
        let minutes = mealMinutes(for: relation)
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

    /// FR9.8.2 扣减矩阵（function-spec 权威文案：已服用/记录不适 → 两线各−1；
    /// 显式跳过 → 两线均免扣（唯一已知未服情形）；忘记/无操作 miss → 安全线−1、
    /// 确认线 0；稍后挂起待决议）：
    /// - taken / discomfort：两线各扣（服用事实成立）
    /// - skipped：两线均免扣（库存实际未消耗）
    /// - missed：仅计划轨扣（安全侧偏置：未知按计划消耗推进，确认线不动）
    /// - snoozed：两线都不扣（临时延后，非终态动作）
    public static func applyResolution(_ inv: DualTrackInventory, units: Double, action: DoseUserAction) -> DualTrackInventory {
        let d = deduction(for: action, units: units)
        var out = inv
        if d.plan > 0 { out = deductPlan(out, units: d.plan) }
        if d.confirmed > 0 { out = deductConfirmed(out, units: d.confirmed) }
        return out
    }

    /// FR9.8.2 扣减矩阵的**唯一编码**：给定用户动作，返回两条轨各自应扣的单位数。
    ///
    /// `applyResolution`（单批次）与 Infrastructure 的 FEFO 批次分配都必须由此派生。
    /// 此前 Infrastructure 用两个三元表达式重新编码了同一张矩阵，同一次规格修订里
    /// 两处各改一遍才对——漏一处就让 dose_lot_allocation 账本与 Domain 判定背离
    /// （双轨库存的报表/续药告警同时失真），且属「BR 规则只在 Domain」的违例。
    public static func deduction(for action: DoseUserAction, units: Double) -> (plan: Double, confirmed: Double) {
        switch action {
        case .snoozed, .skipped:   return (0, 0)          // 已知未服，库存未消耗
        case .taken, .discomfort:  return (units, units)  // 服用事实成立
        case .missed:              return (units, 0)      // 未知按计划推进（安全侧偏置）
        }
    }

    /// 续药告警（FR9.8.3）：安全线余量 ≤7 天当量 → 需告警（偏早）
    public static func refillAlertNeeded(_ inv: DualTrackInventory, dailyPlanUnits: Double, at date: Date) -> Bool {
        refillTier(inv, dailyPlanUnits: dailyPlanUnits, at: date) != nil
    }

    /// 续药分级（FR9.8.3 三级触达）：按**安全线**剩余天数定级。
    /// 用安全线而非确认线是 ADR-009 不可协商的取向——误差必须偏向**更早**告警。
    public enum RefillTier: String, Sendable, Equatable, CaseIterable, Codable {
        case t14, t7, t3
        /// 触发阈值（剩余天数 ≤ 该值）
        public var daysLeftThreshold: Double {
            switch self {
            case .t14: return 14
            case .t7:  return 7
            case .t3:  return 3
            }
        }
    }

    /// 当前应处的最紧急档位；不需告警返回 nil。过期批次直接按最紧急档处理。
    ///
    /// 契约（评审补注）：本规则**不读 status**——余量 0 的批次按最紧急档持续触达，
    /// 这是 ADR-009「偏早告警」的有意取向（用户未处理就持续提醒）；status 过滤
    /// （只对 active 批次告警）是**调用方**职责（见 MedicationStore.refillSummary
    /// 的 `WHERE status = 'active'`）。不要把 status 判断塞进本函数——那会让
    /// 「已耗尽未盘点」的批次静默退出告警，违反偏早红线。
    public static func refillTier(_ inv: DualTrackInventory, dailyPlanUnits: Double,
                                  at date: Date) -> RefillTier? {
        guard dailyPlanUnits > 0 else { return nil }
        if let e = inv.expireAt, e < date { return .t3 }      // 过期即最紧急
        let daysLeft = inv.remainingPlanUnits / dailyPlanUnits
        // 从最紧急往回判，返回命中的最紧急档
        for tier in [RefillTier.t3, .t7, .t14] where daysLeft <= tier.daysLeftThreshold {
            return tier
        }
        return nil
    }

    /// **零确认存活（M2 一票否决，FR9.8「零确认存活动作条款」）**
    ///
    /// 安全线是**计划驱动**的：用户建完计划后一个动作都不做，安全线也必须按
    /// 排程自行推进，续药提醒因此照常分级触达。
    ///
    /// 这条之所以必须单独存在：`applyResolution` 需要一个 `DoseUserAction` 才会
    /// 扣减，而「零确认」恰恰意味着**永远不会有 action 传进来**——安全线于是
    /// 永不减少、续药告警永不触发。用户什么都不做时反而收不到「该买药了」，
    /// 正是这条红线要防的失效。计划轨的推进权因此不能挂在用户动作上。
    ///
    /// - Parameter elapsedScheduledDoses: 区间内**应服**剂次数（由排程引擎给出，
    ///   与用户是否确认无关）。
    ///
    /// ⚠️ 当前**无生产调用方**（仅 M2DomainTests 覆盖）。线上走的是
    /// `MedicationStore.materializeMissed`：把过宽限的无动作剂量物化成 `missed`，
    /// 再经扣减矩阵推进计划轨。二者语义等价但路径不同——本函数是「按区间批量推进」，
    /// materializeMissed 是「按剂量逐条补账」。保留是因为它是 FR9.8.8 的可单测纯规则；
    /// 若后续确认不再需要批量口径，应连同测试一并删除，不要让它悄悄留成第二套真相。
    public static func advancePlanTrack(_ inv: DualTrackInventory,
                                        elapsedScheduledDoses: Int,
                                        unitsPerDose: Double) -> DualTrackInventory {
        guard elapsedScheduledDoses > 0, unitsPerDose > 0 else { return inv }
        return deductPlan(inv, units: Double(elapsedScheduledDoses) * unitsPerDose)
    }

    /// 零确认场景下，从建计划到 `now` 期间应触达的**全部**续药档位（升序）。
    /// 逐日推进安全线并记录首次跨越各档的时刻——用于验证「三级触达全发生」，
    /// 也用于补发（某档触发时 App 未运行则下次启动补发，不静默吞掉）。
    public static func refillTiersFired(initialUnits: Double,
                                        dailyPlanUnits: Double,
                                        from start: Date, to now: Date,
                                        calendar: Calendar = .current) -> [(tier: RefillTier, at: Date)] {
        guard dailyPlanUnits > 0, initialUnits > 0, now > start else { return [] }
        var fired: [(RefillTier, Date)] = []
        var pending = Set(RefillTier.allCases)
        let totalDays = Int(now.timeIntervalSince(start) / 86400)
        for day in 0...max(0, totalDays) {
            guard let at = calendar.date(byAdding: .day, value: day, to: start) else { continue }
            let remaining = max(0, initialUnits - Double(day) * dailyPlanUnits)
            let daysLeft = remaining / dailyPlanUnits
            for tier in [RefillTier.t14, .t7, .t3]
            where pending.contains(tier) && daysLeft <= tier.daysLeftThreshold {
                pending.remove(tier)
                fired.append((tier, at))
            }
        }
        return fired.sorted { $0.1 < $1.1 }
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
