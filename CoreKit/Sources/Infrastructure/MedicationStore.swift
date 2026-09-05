#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// M1b 用药数据仓（actor，GRDB）：
/// - medication / medication_plan / stock_lot / medication_dose_log / dose_lot_allocation 写入
/// - DoseSource 实现：对账输入（active 计划的 pending 剂量 → DoseDeliveryFact）
/// - 双轨扣减与服药确认落库
public actor MedicationStore: DoseSource {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    // MARK: - 计划与批次

    public func createPlan(planId: UUID, patientId: UUID, medicationId: UUID,
                           schedule: MedicationSchedule, status: PlanStatus,
                           startDate: Date, endDate: Date?) async throws {
        try await writer.write { db in
            let scheduleJSON = String(data: try JSONEncoder().encode(schedule), encoding: .utf8) ?? "{}"
            try db.execute(
                sql: """
                INSERT INTO medication_plan
                  (id, patient_id, medication_id, status, schedule_json, start_date, end_date, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [planId.uuidString, patientId.uuidString, medicationId.uuidString,
                            status.rawValue, scheduleJSON, startDate.timeIntervalSince1970,
                            endDate?.timeIntervalSince1970, Date().timeIntervalSince1970,
                            Date().timeIntervalSince1970])
        }
    }

    public func createMedication(id: UUID = UUID(), patientId: UUID, name: String,
                                 spec: String?, unitKind: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO medication (id, patient_id, generic_name, spec, unit_kind, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [id.uuidString, patientId.uuidString, name, spec, unitKind,
                            Date().timeIntervalSince1970, Date().timeIntervalSince1970])
        }
    }

    public func createLot(lot: DualTrackInventory, patientId: UUID, medicationId: UUID) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO stock_lot
                  (id, patient_id, medication_id, total_units, unit_kind,
                   remaining_plan_units, remaining_confirmed_units, expire_at,
                   status, last_reconciled_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [lot.lotId.uuidString, patientId.uuidString, medicationId.uuidString,
                            lot.totalUnits, lot.unitKind, lot.remainingPlanUnits,
                            lot.remainingConfirmedUnits, lot.expireAt?.timeIntervalSince1970,
                            lot.status, Date().timeIntervalSince1970])
        }
    }

    // MARK: - 服药确认（BR-004：确认动作与扣减同事务）

    /// 服药确认「服了」（评审修正 P0：UPDATE 物化行而非插孤儿行——否则动作
    /// 对 deliveryFacts 不可见，已服仍重发、可重复扣减，BR-004 生产链失效）。
    /// 同事务：写 user_action + 按 FR9.8.2 矩阵扣两线 + 写 dose_lot_allocation。
    public func confirmTaken(notifyId: String, patientId: UUID) async throws {
        try await writer.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT d.id, d.dose_units, d.user_action, p.medication_id
                FROM medication_dose_log d
                JOIN medication_plan p ON p.id = d.plan_id
                WHERE d.id = ?
                """, arguments: [notifyId]) else {
                throw StoreError.doseNotFound(notifyId)
            }
            // 幂等（评审 S0-2）：已决议的行不得重复扣减
            if (row["user_action"] as String?) != nil {
                throw StoreError.alreadyResolved(notifyId)
            }
            let units = (row["dose_units"] as Double?) ?? 1
            let medicationId = UUID(uuidString: row["medication_id"] as String) ?? UUID()
            try db.execute(sql: """
                UPDATE medication_dose_log
                SET user_action = 'taken', acted_at = ?
                WHERE id = ?
                """, arguments: [Date().timeIntervalSince1970, notifyId])
            try applyResolutionOnLots(patientId: patientId, medicationId: medicationId,
                                notifyId: notifyId, units: units, action: .taken, db: db)
        }
    }

    /// 跳过/忘记/不适/稍后：UPDATE 物化行 + FR9.8.2 矩阵（skipped 两线均免扣、
    /// missed 仅计划轨扣、discomfort 两线各扣；snoozed 两线不动，稍后由对账重排）。
    /// reason：FR9.5 跳过必选原因/不适备注，落 dose_log.note（如实记录，不美化）。
    public func recordAction(notifyId: String, action: DoseUserAction, reason: String? = nil) async throws {
        guard action != .taken else {
            throw StoreError.takenMustUseConfirm(notifyId)   // §7：不得静默 return
        }
        try await writer.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT d.id, d.dose_units, p.patient_id, p.medication_id
                FROM medication_dose_log d
                JOIN medication_plan p ON p.id = d.plan_id
                WHERE d.id = ?
                """, arguments: [notifyId]) else {
                throw StoreError.doseNotFound(notifyId)
            }
            let units = (row["dose_units"] as Double?) ?? 1
            let patientId = UUID(uuidString: row["patient_id"] as String) ?? UUID()
            let medicationId = UUID(uuidString: row["medication_id"] as String) ?? UUID()
            try db.execute(sql: """
                UPDATE medication_dose_log
                SET user_action = ?, acted_at = ?, note = ?
                WHERE id = ?
                """, arguments: [action.rawValue, Date().timeIntervalSince1970, reason, notifyId])
            try applyResolutionOnLots(patientId: patientId, medicationId: medicationId,
                                notifyId: notifyId, units: units, action: action, db: db)
        }
    }

    public enum StoreError: Error, LocalizedError {
        case doseNotFound(String)
        case alreadyResolved(String)
        case takenMustUseConfirm(String)
        public var errorDescription: String? { "剂量行操作失败: \(self)" }
    }

    // MARK: - 零确认存活（FR9.8.8 / dev-pm §3.4 M2 一票否决）

    /// **计划驱动补账**：把「已过宽限期、仍无任何用户动作」的剂量行物化为
    /// `.missed`，并只扣**安全线**（FR9.8.2：忘记/无操作 → 安全线−1、确认线 0）。
    ///
    /// 为什么必须单独存在：安全线的推进此前只挂在用户动作上
    /// （`confirmTaken` / `recordAction` → `applyResolutionOnLots`），而「零确认」
    /// 恰恰意味着**永远不会有动作传进来**——安全线于是永不减少、续药提醒永不
    /// 触发。用户建完计划后什么都不做，反而收不到「该买药了」，这正是
    /// FR9.8.8「零确认存活动作条款」要防的失效形态。
    ///
    /// - 幂等：`user_action IS NULL` 守卫，已物化行不重复处理；
    /// - 每行一个事务还是整批一个事务？**整批一个事务**——补账是排程驱动的
    ///   一致性动作，半批提交会让「安全线已扣但行未物化」的中间态可见；
    /// - 宽限语义与对账一致（`isExpiredGrace`：15 分钟），未过宽限的行留给用户。
    @discardableResult
    public func materializeMissed(now: Date, graceInterval: TimeInterval = 15 * 60) async throws -> Int {
        let cutoff = now.addingTimeInterval(-graceInterval)
        return try await writer.write { db -> Int in
            // 目标行：计划 active、已过宽限、无用户动作
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.id, d.dose_units, p.patient_id, p.medication_id
                FROM medication_dose_log d
                JOIN medication_plan p ON p.id = d.plan_id
                WHERE p.status = 'active'
                  AND d.user_action IS NULL
                  AND d.scheduled_for < ?
                """, arguments: [cutoff.timeIntervalSince1970])
            var processed = 0
            for row in rows {
                let notifyId = row["id"] as String
                let units = (row["dose_units"] as Double?) ?? 1
                let patientId = UUID(uuidString: row["patient_id"] as String) ?? UUID()
                let medicationId = UUID(uuidString: row["medication_id"] as String) ?? UUID()
                try db.execute(sql: """
                    UPDATE medication_dose_log
                    SET user_action = 'missed', acted_at = ?
                    WHERE id = ? AND user_action IS NULL
                    """, arguments: [now.timeIntervalSince1970, notifyId])
                guard db.changesCount > 0 else { continue }   // 并发下已被决议，跳过
                try applyResolutionOnLots(patientId: patientId, medicationId: medicationId,
                                          notifyId: notifyId, units: units,
                                          action: .missed, db: db)
                processed += 1
            }
            return processed
        }
    }

    /// 某计划下已物化的剂量行数（测试/月报用）
    public func doseCount(planId: UUID, from: Date, to: Date) async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM medication_dose_log
                WHERE plan_id = ? AND scheduled_for >= ? AND scheduled_for <= ?
                """, arguments: [planId.uuidString,
                                 from.timeIntervalSince1970, to.timeIntervalSince1970]) ?? 0
        }
    }

    // MARK: - 消耗差异月报（FR9.8.5）

    /// 月报输入 = 两线差值，逐日可溯。**纯事实聚合**，句式由 Domain 的
    /// `InventoryMonthlyReport.statement` 唯一产出（禁止任何评价/评分句式，
    /// 负清单由 `InventoryReportRules.violation` 一票否决）。
    public func monthlyReport(patientId: UUID, from: Date, to: Date) async throws -> InventoryMonthlyReport {
        try await writer.read { db in
            let counts = try Row.fetchOne(db, sql: """
                SELECT
                  COUNT(*) AS planned,
                  -- discomfort 与 taken 同属「服用事实成立」（FR9.8.2 扣减矩阵：两线各扣），
                  -- 因此必须计入确认桶。此前归入 missed 会让 FR9.8.5 两线差异报告
                  -- 与库存台账对同一剂量给出相反口径。
                  SUM(CASE WHEN user_action IN ('taken','discomfort') THEN 1 ELSE 0 END) AS confirmed,
                  SUM(CASE WHEN user_action = 'skipped' THEN 1 ELSE 0 END) AS skipped,
                  SUM(CASE WHEN user_action IS NULL OR user_action = 'missed'
                      THEN 1 ELSE 0 END) AS missed
                FROM medication_dose_log d
                JOIN medication_plan p ON p.id = d.plan_id
                WHERE p.patient_id = ? AND d.scheduled_for >= ? AND d.scheduled_for <= ?
                """, arguments: [patientId.uuidString,
                                 from.timeIntervalSince1970, to.timeIntervalSince1970])
            return InventoryReportRules.report(
                periodStart: from, periodEnd: to,
                planned: Int(counts?["planned"] as Int64? ?? 0),
                confirmed: Int(counts?["confirmed"] as Int64? ?? 0),
                skipped: Int(counts?["skipped"] as Int64? ?? 0),
                missed: Int(counts?["missed"] as Int64? ?? 0))
        }
    }

    // MARK: - 家庭药箱摘要（FR9.8.3 续药卡 / FR9.8.7「约剩 N 天」）

    /// 批次级摘要：安全线剩余 + 确认线剩余 + 当前续药档位 + 诚实性天数估算。
    /// `约剩 N 天·按计划估算` 的 N 来自**安全线 ÷ 计划日当量**（向上取整不实——
    /// 诚实性文案要求「约」，故保留一位小数取整向上，绝不精确到小时装精确）。
    public func inventorySummary(patientId: UUID, now: Date) async throws -> [InventorySummaryItem] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT l.id, l.medication_id, m.generic_name, m.spec, l.total_units,
                       l.unit_kind, l.remaining_plan_units, l.remaining_confirmed_units,
                       l.expire_at, l.status, l.storage_note
                FROM stock_lot l
                JOIN medication m ON m.id = l.medication_id
                WHERE l.patient_id = ? AND l.status = 'active'
                ORDER BY m.generic_name, l.expire_at
                """, arguments: [patientId.uuidString])
            var items: [InventorySummaryItem] = []
            for row in rows {
                // 日当量：active 计划的 schedule_json 在 Swift 侧解码估算——
                // 枚举 JSON 形态多样（fixed/interval/meal/…），SQL JSON1 路径
                // 会静默失配，宁可多写几行解码也不把「约剩 N 天」建在静默失效上。
                let medicationId = row["medication_id"] as String
                let schedules = try String.fetchAll(db, sql: """
                    SELECT schedule_json FROM medication_plan
                    WHERE medication_id = ? AND status = 'active'
                    """, arguments: [medicationId])
                var daily = 0.0
                for json in schedules {
                    guard let data = json.data(using: .utf8) else { continue }
                    // 损坏的 schedule_json 跳过该计划（与 materializeWindow 同语义；
                    // 不用 try? —— tech-spec §7 红线）
                    let schedule: MedicationSchedule
                    do { schedule = try JSONDecoder().decode(MedicationSchedule.self, from: data) }
                    catch { continue }
                    daily += Self.estimatedDailyUnits(schedule)
                }
                let planUnits = row["remaining_plan_units"] as Double
                let confirmedUnits = row["remaining_confirmed_units"] as Double
                var inv = DualTrackInventory(lotId: UUID(uuidString: row["id"] as String) ?? UUID(),
                                             totalUnits: row["total_units"] as Double,
                                             unitKind: row["unit_kind"] as String,
                                             expireAt: (row["expire_at"] as Double?).map { Date(timeIntervalSince1970: $0) })
                inv.remainingPlanUnits = planUnits
                inv.remainingConfirmedUnits = confirmedUnits
                let tier = InventoryRules.refillTier(inv, dailyPlanUnits: daily, at: now)
                items.append(InventorySummaryItem(
                    lotId: UUID(uuidString: row["id"] as String) ?? UUID(),
                    medicationName: row["generic_name"] as String,
                    spec: row["spec"] as String?,
                    unitKind: row["unit_kind"] as String,
                    remainingPlanUnits: planUnits,
                    remainingConfirmedUnits: confirmedUnits,
                    expireAt: (row["expire_at"] as Double?).map { Date(timeIntervalSince1970: $0) },
                    storageNote: row["storage_note"] as String?,
                    approxDaysLeft: daily > 0 ? Int(ceil(planUnits / daily)) : nil,
                    refillTier: tier))
            }
            return items
        }
    }

    /// 盘点归真（FR9.8.5 往返）：写入**用户确认后的**实物清点，两线同时重置为
    /// 物理真值 + 记审计。归真必须显式调用且经确认（Domain 侧 `needsConfirmation`
    /// 已判差异非零），本方法不自行裁决差异——裁决发生在调用方确认之后。
    public func reconcileLot(lotId: UUID, physicalCount: Double, at: Date,
                             note: String? = nil, auditSink: ((String, String) async throws -> Void)? = nil) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE stock_lot
                SET remaining_plan_units = ?, remaining_confirmed_units = ?,
                    last_reconciled_at = ?
                WHERE id = ?
                """, arguments: [physicalCount, physicalCount, at.timeIntervalSince1970,
                                 lotId.uuidString])
            guard db.changesCount > 0 else {
                throw StoreError.doseNotFound(lotId.uuidString)
            }
            // 审查修复：审计与业务同事务（对齐「审计不落半条」纪律）——
            // 原实现提交后才经 async auditSink 写审计，审计失败即留下
            // 无审计的库存归真记录。事务内直落 audit_event（与
            // AuditLogWriter 同表同列），entity_id_hash 脱敏与 writer 一致。
            if auditSink != nil {
                let digest = Domain.SHA256.hash(data: Data(lotId.uuidString.utf8))
                var hex = ""
                var it = digest.makeIterator()
                while let byte = it.next() { hex += String(format: "%02x", byte) }
                try db.execute(sql: """
                    INSERT INTO audit_event (id, actor_local, action, entity_type, entity_id_hash, at, meta_json)
                    VALUES (?, 'local', 'inventory.reconcile', 'stock_lot', ?, ?, ?)
                    """, arguments: [UUID().uuidString, hex, at.timeIntervalSince1970,
                                     "count=\(physicalCount) note=\(note ?? "")"])
            }
        }
    }

    /// 日均当量估算（FR9.8.7「约剩 N 天·按计划估算」）。诚实性纪律：
    /// 只作「约」字号的估算，且对多计划取**最大值**（保守——宁可估算天数更少，
    /// 也不让用户以为药比实际多）。asNeeded 无排程，不计入日当量。
    static func estimatedDailyUnits(_ schedule: MedicationSchedule) -> Double {
        switch schedule {
        case .fixed(let times): return Double(max(1, times.count))
        case .interval(let everyMinutes, _):
            let perDay = 1440.0 / Double(max(1, everyMinutes))
            return min(perDay, 24)
        case .meal(let relations): return Double(max(1, relations.count))
        case .asNeeded: return 0
        case .cycle(let everyDays, let daysOn): return Double(daysOn) / Double(max(1, everyDays))
        case .taper(let stages):
            // 未来段不确定，取各阶段日当量最大值（保守）
            return stages.map { Double($0.times.count) * $0.doseUnits }.max() ?? 1
        }
    }

    public struct InventorySummaryItem: Sendable, Equatable, Identifiable {
        public var lotId: UUID
        public var medicationName: String
        public var spec: String?
        public var unitKind: String
        public var id: UUID { lotId }
        public var remainingPlanUnits: Double
        public var remainingConfirmedUnits: Double
        public var expireAt: Date?
        /// 存放位置（FR9.10：未知/空 → 进入批次补录待办队列）
        public var storageNote: String?
        /// 约剩 N 天·按计划估算（FR9.8.7）；无 active 计划时为 nil（不装精确）
        public var approxDaysLeft: Int?
        public var refillTier: InventoryRules.RefillTier?
        public init(lotId: UUID, medicationName: String, spec: String?, unitKind: String,
                    remainingPlanUnits: Double, remainingConfirmedUnits: Double,
                    expireAt: Date?, storageNote: String? = nil,
                    approxDaysLeft: Int?, refillTier: InventoryRules.RefillTier?) {
            self.lotId = lotId; self.medicationName = medicationName; self.spec = spec
            self.unitKind = unitKind; self.remainingPlanUnits = remainingPlanUnits
            self.remainingConfirmedUnits = remainingConfirmedUnits; self.expireAt = expireAt
            self.storageNote = storageNote
            self.approxDaysLeft = approxDaysLeft; self.refillTier = refillTier
        }
    }

    // MARK: - 滚动预排窗口（§5.4：只物化未来 7 天，每日对账滚动补排）

    /// 为全部 active 计划物化窗口内剂量行（幂等）。dose_log.plan_id 必须指向真实
    /// 计划——否则 DoseSource.deliveryFacts 的 JOIN 恒空，提醒链断裂。
    /// 评审修正 P0：窗口日界必须以 now 为锚——fromDay 硬编码 1 会让开立超过
    /// 7 天的老计划全部生成在过去被过滤，inserted=0 永不再物化。
    /// 返回本窗口新物化的行数。
    public func materializeWindow(now: Date, calendar: Calendar) async throws -> Int {
        let windowEnd = now.addingTimeInterval(TimeInterval(ReconcileEngine.preScheduleWindowDays * 86400))
        // 返回式写闭包：不在闭包内突变捕获变量（Swift 6 并发纪律——
        // 「mutation of captured var in concurrently-executing code」是 6 模式下的错误）
        return try await writer.write { db -> Int in
            var inserted = 0
            let plans = try Row.fetchAll(db, sql: """
                SELECT id, patient_id, schedule_json, start_date, end_date
                FROM medication_plan WHERE status = 'active'
                """)
            for plan in plans {
                let planId = UUID(uuidString: plan["id"] as String) ?? UUID()
                let startDate = Date(timeIntervalSince1970: plan["start_date"] as Double)
                let endDate = (plan["end_date"] as Double?).map { Date(timeIntervalSince1970: $0) }
                guard let json = (plan["schedule_json"] as String?)?.data(using: .utf8) else { continue }
                let schedule: MedicationSchedule
                do { schedule = try JSONDecoder().decode(MedicationSchedule.self, from: json) }
                catch { continue }   // 损坏的 schedule_json 跳过该计划（§7 禁 try?）
                // 以 now 锚定日界：计划期第 N 天 = startDate 后第 N-1 天
                let dayOfPlan = calendar.dateComponents([.day], from: calendar.startOfDay(for: startDate),
                                                        to: calendar.startOfDay(for: now)).day ?? 0
                let fromDay = max(1, dayOfPlan + 1)
                let toDay = fromDay + ReconcileEngine.preScheduleWindowDays
                let (doses, _) = DoseScheduleEngine.doses(
                    schedule: schedule, planId: planId, startDate: startDate,
                    fromDay: fromDay, toDay: toDay, calendar: calendar)
                for d in doses {
                    guard d.dueAt >= now && d.dueAt <= windowEnd else { continue }
                    if let end = endDate, d.dueAt > end.addingTimeInterval(86400) { continue }   // 到期次日不物化
                    try db.execute(
                        sql: """
                        INSERT INTO medication_dose_log (id, plan_id, scheduled_for, dose_units, delivery_state, user_action)
                        VALUES (?, ?, ?, ?, 'planned', NULL)
                        ON CONFLICT(id) DO NOTHING
                        """,
                        arguments: [d.notifyId, planId.uuidString, d.dueAt.timeIntervalSince1970, d.doseUnits])
                    inserted += db.changesCount
                }
            }
            return inserted
        }
    }

    // MARK: - DoseSource（对账输入）

    public func deliveryFacts(from: Date, to: Date) async throws -> [DoseDeliveryFact] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.id AS dose_id, d.scheduled_for, d.dose_units, d.user_action, d.delivery_state,
                       m.generic_name, m.spec, m.unit_kind, p.patient_id
                FROM medication_dose_log d
                JOIN medication_plan p ON p.id = d.plan_id
                JOIN medication m ON m.id = p.medication_id
                WHERE p.status = 'active' AND d.scheduled_for >= ? AND d.scheduled_for <= ?
                """, arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970])
            return rows.map { row in
                let scheduledFor = Date(timeIntervalSince1970: row["scheduled_for"] as Double)
                let action = (row["user_action"] as String?).flatMap(DoseUserAction.init(rawValue:))
                return DoseDeliveryFact(
                    dose: ScheduledDose(dueAt: scheduledFor,
                                        doseUnits: (row["dose_units"] as Double?) ?? 1,
                                        notifyId: row["dose_id"] as String),
                    delivered: (row["delivery_state"] as String) == "delivered",
                    action: action,
                    isDueSoon: scheduledFor <= from.addingTimeInterval(30 * 60),
                    isExpiredGrace: scheduledFor < from.addingTimeInterval(-15 * 60),
                    medicationName: row["generic_name"] as String?,
                    spec: row["spec"] as String?,
                    unitKind: row["unit_kind"] as String?,
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)))
            }
        }
    }

    public func markAwaitingUser(_ notifyId: String) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE medication_dose_log SET delivery_state = 'delivered'
                WHERE id = ?
                """, arguments: [notifyId])
        }
    }

    // MARK: - FR9.16 补录/追溯服药（落到实际发生时间，如实记录，不引入「补服」特殊态）

    /// 补记「已服用」：错过的时段可在过后补录，落在**实际发生时间**并如实记录。
    /// 双轨按 FR9.8.2 矩阵各 −1（taken）；计划历史如实呈现补录时间点，不美化。
    /// 若该时段已有物化行 → UPDATE 该行；否则 INSERT 新行（补录本身即证据）。
    public func recordTakenAt(planId: UUID, patientId: UUID, medicationId: UUID,
                              actualTime: Date, doseUnits: Double = 1,
                              notifyId: String = UUID().uuidString) async throws {
        try await writer.write { db in
            guard try Row.fetchOne(db, sql: "SELECT id FROM medication_plan WHERE id = ? AND status = 'active'",
                                   arguments: [planId.uuidString]) != nil else {
                throw StoreError.doseNotFound(planId.uuidString)
            }
            // 幂等：同一补录 id 重复提交不重复扣减
            if let existing = try Row.fetchOne(db, sql: "SELECT user_action FROM medication_dose_log WHERE id = ?",
                                               arguments: [notifyId]),
               (existing["user_action"] as String?) != nil {
                throw StoreError.alreadyResolved(notifyId)
            }
            try db.execute(sql: """
                INSERT INTO medication_dose_log (id, plan_id, scheduled_for, dose_units, delivery_state, user_action, acted_at, note)
                VALUES (?, ?, ?, ?, 'delivered', 'taken', ?, 'backfill')
                ON CONFLICT(id) DO UPDATE SET user_action = 'taken', acted_at = excluded.acted_at
                """, arguments: [notifyId, planId.uuidString, actualTime.timeIntervalSince1970,
                                 doseUnits, actualTime.timeIntervalSince1970])
            try applyResolutionOnLots(patientId: patientId, medicationId: medicationId,
                                      notifyId: notifyId, units: doseUnits, action: .taken, db: db)
        }
    }

    // MARK: - FR9.11 批次有效期分级提醒（30/7/当日三级；阈值可自定义更短窗口）

    /// 窗口内到期的活跃批次（默认 30 天，FR9.11 三级通知的数据源）。
    /// 过期批次不在此列——它们已被排除出可用库存（applyResolutionOnLots 过滤）。
    public func expiringLots(patientId: UUID, within days: Int = 30, now: Date = Date())
        async throws -> [InventorySummaryItem] {
        let window = now.addingTimeInterval(TimeInterval(days) * 86400)
        return try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT l.id, l.medication_id, m.generic_name, m.spec, l.total_units,
                       l.unit_kind, l.remaining_plan_units, l.remaining_confirmed_units,
                       l.expire_at, l.status
                FROM stock_lot l
                JOIN medication m ON m.id = l.medication_id
                WHERE l.patient_id = ? AND l.status = 'active'
                  AND l.expire_at IS NOT NULL AND l.expire_at <= ?
                ORDER BY l.expire_at
                """, arguments: [patientId.uuidString, window.timeIntervalSince1970])
            return rows.map { row in
                InventorySummaryItem(
                    lotId: UUID(uuidString: row["id"] as String) ?? UUID(),
                    medicationName: row["generic_name"] as String,
                    spec: row["spec"] as String?,
                    unitKind: row["unit_kind"] as String,
                    remainingPlanUnits: row["remaining_plan_units"] as Double,
                    remainingConfirmedUnits: row["remaining_confirmed_units"] as Double,
                    expireAt: (row["expire_at"] as Double?).map { Date(timeIntervalSince1970: $0) },
                    approxDaysLeft: nil, refillTier: nil)
            }
        }
    }

    // MARK: - FR9.15/FR9.16 计划查询投影（详情页/日程条/补记）

    public struct PlanRow: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var patientId: UUID
        public var medicationId: UUID
        public var medicationName: String
        public var spec: String?
        public var status: String
        public var schedule: MedicationSchedule
        public var startDate: Date
        public var endDate: Date?
        public init(id: UUID, patientId: UUID, medicationId: UUID, medicationName: String,
                    spec: String?, status: String, schedule: MedicationSchedule,
                    startDate: Date, endDate: Date?) {
            self.id = id; self.patientId = patientId; self.medicationId = medicationId
            self.medicationName = medicationName; self.spec = spec; self.status = status
            self.schedule = schedule; self.startDate = startDate; self.endDate = endDate
        }
    }

    public struct DoseLogRow: Sendable, Equatable, Identifiable {
        public var notifyId: String
        public var scheduledFor: Date
        public var doseUnits: Double
        public var action: DoseUserAction?
        public var actedAt: Date?
        public var note: String?
        public var id: String { notifyId }
        public init(notifyId: String, scheduledFor: Date, doseUnits: Double,
                    action: DoseUserAction?, actedAt: Date?, note: String?) {
            self.notifyId = notifyId; self.scheduledFor = scheduledFor
            self.doseUnits = doseUnits; self.action = action
            self.actedAt = actedAt; self.note = note
        }
    }

    /// 成员的全部计划（SP-15 列表/详情数据源）
    public func plans(patientId: UUID) async throws -> [PlanRow] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id, p.patient_id, p.medication_id, p.status, p.schedule_json,
                       p.start_date, p.end_date, m.generic_name, m.spec
                FROM medication_plan p
                JOIN medication m ON m.id = p.medication_id
                WHERE p.patient_id = ?
                ORDER BY p.status = 'active' DESC, p.start_date DESC
                """, arguments: [patientId.uuidString])
            return rows.compactMap { row in
                guard let json = (row["schedule_json"] as String?)?.data(using: .utf8) else { return nil }
                guard let schedule = try? JSONDecoder().decode(MedicationSchedule.self, from: json) else { // try?-ok: 损坏的 schedule_json 跳过该计划
                    return nil
                }
                return PlanRow(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: UUID(uuidString: row["patient_id"] as String) ?? UUID(),
                    medicationId: UUID(uuidString: row["medication_id"] as String) ?? UUID(),
                    medicationName: row["generic_name"] as String,
                    spec: row["spec"] as String?,
                    status: row["status"] as String,
                    schedule: schedule,
                    startDate: Date(timeIntervalSince1970: row["start_date"] as Double),
                    endDate: (row["end_date"] as Double?).map { Date(timeIntervalSince1970: $0) })
            }
        }
    }

    public func plan(id: UUID) async throws -> PlanRow? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT p.id, p.patient_id, p.medication_id, p.status, p.schedule_json,
                       p.start_date, p.end_date, m.generic_name, m.spec
                FROM medication_plan p
                JOIN medication m ON m.id = p.medication_id
                WHERE p.id = ?
                """, arguments: [id.uuidString]) else { return nil }
            guard let json = (row["schedule_json"] as String?)?.data(using: .utf8) else { return nil }
            guard let schedule = try? JSONDecoder().decode(MedicationSchedule.self, from: json) else { // try?-ok: 损坏的 schedule_json 视为计划不可读
                return nil
            }
            return PlanRow(
                id: UUID(uuidString: row["id"] as String) ?? UUID(),
                patientId: UUID(uuidString: row["patient_id"] as String) ?? UUID(),
                medicationId: UUID(uuidString: row["medication_id"] as String) ?? UUID(),
                medicationName: row["generic_name"] as String,
                spec: row["spec"] as String?,
                status: row["status"] as String,
                schedule: schedule,
                startDate: Date(timeIntervalSince1970: row["start_date"] as Double),
                endDate: (row["end_date"] as Double?).map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// 计划剂量日志（FR9.16 日程条：本周七日格，已服实心✓/漏服空心!/未来灰）
    public func doseLog(planId: UUID, from: Date, to: Date) async throws -> [DoseLogRow] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, scheduled_for, dose_units, user_action, acted_at, note
                FROM medication_dose_log
                WHERE plan_id = ? AND scheduled_for >= ? AND scheduled_for <= ?
                ORDER BY scheduled_for
                """, arguments: [planId.uuidString, from.timeIntervalSince1970, to.timeIntervalSince1970])
            .map { row in
                DoseLogRow(
                    notifyId: row["id"] as String,
                    scheduledFor: Date(timeIntervalSince1970: row["scheduled_for"] as Double),
                    doseUnits: (row["dose_units"] as Double?) ?? 1,
                    action: (row["user_action"] as String?).flatMap(DoseUserAction.init(rawValue:)),
                    actedAt: (row["acted_at"] as Double?).map { Date(timeIntervalSince1970: $0) },
                    note: row["note"] as String?)
            }
        }
    }

    // MARK: - FR9.9 药品知识卡数据源（医嘱原文经 stock_lot→prescription 关联）

    /// 药品的医嘱原文（知识卡「医生医嘱」来源徽章 A/C）。
    /// 处方与药品无直接外键，经 stock_lot.prescription_id 关联取最近一条。
    public func adviceForMedication(medicationId: UUID) async throws -> String? {
        try await writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT rx.advice_text FROM prescription rx
                JOIN stock_lot l ON l.prescription_id = rx.id
                WHERE l.medication_id = ? AND rx.advice_text IS NOT NULL AND rx.advice_text != ''
                ORDER BY rx.prescribed_at DESC LIMIT 1
                """, arguments: [medicationId.uuidString])
        }
    }

    // MARK: - FR9.18 送达记录（channel 字段供诊断/审计/差异分析）

    /// 记一条送达事实（FR9.7 扩展：channel 字段）。
    /// 记录的是「经哪个通道触达」，与用户确认状态完全分离（BR-004）。
    public func recordDelivery(notifyId: String, doseLogId: String?, channel: ReminderChannelKind,
                               outcome: String, at: Date) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO notification_delivery (id, dose_log_id, scheduled_at, delivered_at, channel, outcome, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [notifyId, doseLogId, at.timeIntervalSince1970,
                                 outcome == "delivered" ? at.timeIntervalSince1970 : nil,
                                 channel.rawValue, outcome, at.timeIntervalSince1970])
        }
    }

    // MARK: - FR24.5 同机照护者（跨成员待确认聚合，BR-001 显式携带成员）

    /// 全部家庭成员待确认剂量（FR24.5「帮家人处理」数据源）。
    /// 与 deliveryFacts 不同：**跨成员聚合**且每行携带 patient_id/成员名——
    /// 代确认必须落回剂量所属成员，禁止用 currentPatientId 张冠李戴（BR-001）。
    public func familyPendingDoses(from: Date, to: Date) async throws -> [FamilyPendingDose] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.id AS dose_id, d.scheduled_for, d.dose_units,
                       p.patient_id, m.generic_name, m.spec, m.unit_kind,
                       COALESCE(pp.display_name, '') AS patient_name
                FROM medication_dose_log d
                JOIN medication_plan p ON p.id = d.plan_id
                JOIN medication m ON m.id = p.medication_id
                LEFT JOIN patient_profile pp ON pp.id = p.patient_id
                WHERE p.status = 'active' AND d.user_action IS NULL
                  AND d.scheduled_for >= ? AND d.scheduled_for <= ?
                ORDER BY d.scheduled_for
                """, arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970])
            return rows.map { row in
                FamilyPendingDose(
                    patientId: UUID(uuidString: row["patient_id"] as String) ?? UUID(),
                    patientName: row["patient_name"] as String,
                    medicationName: row["generic_name"] as String,
                    spec: row["spec"] as String?,
                    dose: ScheduledDose(dueAt: Date(timeIntervalSince1970: row["scheduled_for"] as Double),
                                        doseUnits: (row["dose_units"] as Double?) ?? 1,
                                        notifyId: row["dose_id"] as String))
            }
        }
    }
}

/// FR24.5 家庭待确认剂量投影（携带成员，代确认落回该成员）
public struct FamilyPendingDose: Sendable, Equatable, Identifiable {
    public var patientId: UUID
    public var patientName: String
    public var medicationName: String
    public var spec: String?
    public var dose: ScheduledDose
    public var id: String { dose.notifyId }
    public init(patientId: UUID, patientName: String, medicationName: String,
                spec: String?, dose: ScheduledDose) {
        self.patientId = patientId; self.patientName = patientName
        self.medicationName = medicationName; self.spec = spec; self.dose = dose
    }
}

/// FR9.8.2 扣减矩阵落库（同事务）：按 FEFO 在**本药品**活跃且未过期批次上分配
/// （评审 S1-1：不按 medication 过滤会把 A 药确认扣到 B 药批；过期批不得作来源）。
/// 自由函数：在 writer.write 的同步闭包内调用，无 actor 隔离问题（Swift 6 显式 self 纪律）。
func applyResolutionOnLots(patientId: UUID, medicationId: UUID, notifyId: String, units: Double,
                                   action: DoseUserAction, db: Database) throws {
        var inventories: [DualTrackInventory] = []
        for row in try Row.fetchAll(db, sql: """
            SELECT * FROM stock_lot
            WHERE patient_id = ? AND medication_id = ? AND status = 'active'
              AND (expire_at IS NULL OR expire_at > ?)
            """, arguments: [patientId.uuidString, medicationId.uuidString,
                             Date().timeIntervalSince1970]) {
            var inv = DualTrackInventory(lotId: UUID(uuidString: row["id"] as String) ?? UUID(),
                                         totalUnits: row["total_units"] as Double,
                                         unitKind: row["unit_kind"] as String,
                                         expireAt: (row["expire_at"] as Double?).map { Date(timeIntervalSince1970: $0) })
            inv.remainingPlanUnits = row["remaining_plan_units"] as Double
            inv.remainingConfirmedUnits = row["remaining_confirmed_units"] as Double
            inventories.append(inv)
        }
        // FR9.8.2 扣减矩阵由 Domain 单一编码派生（InventoryRules.deduction），
        // 不在此重新编码——矩阵是 BR 规则，只能有一处定义
        let matrix = InventoryRules.deduction(for: action, units: units)
        var planRemaining = matrix.plan
        var confirmedRemaining = matrix.confirmed
        // 双轨账本：planned_units 记录计划线扣减，confirmed_units 记录确认线扣减，
        // 二者独立——原实现把 confirmedTake 同时写入两列，导致计划线账本失真、
        // 安全线（续药提醒）计算错误（FR9.8 双轨语义）。
        var allocations: [(lotId: UUID, planUnits: Double, confirmedUnits: Double)] = []
        for sortedLot in InventoryRules.fefoOrder(inventories) {
            guard planRemaining > 0 || confirmedRemaining > 0 else { break }
            guard sortedLot.status == "active",
                  let i = inventories.firstIndex(where: { $0.lotId == sortedLot.lotId }) else { continue }
            var lot = inventories[i]
            let planTake = min(lot.remainingPlanUnits, planRemaining)
            let confirmedTake = min(lot.remainingConfirmedUnits, confirmedRemaining)
            if planTake > 0 { lot = InventoryRules.deductPlan(lot, units: planTake); planRemaining -= planTake }
            if confirmedTake > 0 { lot = InventoryRules.deductConfirmed(lot, units: confirmedTake); confirmedRemaining -= confirmedTake }
            if planTake > 0 || confirmedTake > 0 {
                inventories[i] = lot
                allocations.append((lot.lotId, planTake, confirmedTake))
            }
        }
        for lot in inventories {
            try db.execute(sql: """
                UPDATE stock_lot SET remaining_plan_units = ?, remaining_confirmed_units = ?
                WHERE id = ?
                """, arguments: [lot.remainingPlanUnits, lot.remainingConfirmedUnits, lot.lotId.uuidString])
        }
        for a in allocations {   // 追加时已过滤零扣减行（planTake/confirmedTake 双零不入账）
            try db.execute(sql: """
                INSERT INTO dose_lot_allocation (dose_log_id, stock_lot_id, planned_units, confirmed_units)
                VALUES (?, ?, ?, ?)
                """, arguments: [notifyId, a.lotId.uuidString, a.planUnits, a.confirmedUnits])
        }
    }
#endif
