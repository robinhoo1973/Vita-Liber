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
            try Self.applyResolution(patientId: patientId, medicationId: medicationId,
                                notifyId: notifyId, units: units, action: .taken, db: db)
        }
    }

    /// 跳过/忘记/不适/稍后：UPDATE 物化行 + FR9.8.2 矩阵（仅计划轨扣；
    /// snoozed 两线不动，稍后由对账重排）
    public func recordAction(notifyId: String, action: DoseUserAction) async throws {
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
                SET user_action = ?, acted_at = ?
                WHERE id = ?
                """, arguments: [action.rawValue, Date().timeIntervalSince1970, notifyId])
            try Self.applyResolution(patientId: patientId, medicationId: medicationId,
                                notifyId: notifyId, units: units, action: action, db: db)
        }
    }

    /// FR9.8.2 扣减矩阵落库（同事务）：按 FEFO 在**本药品**活跃且未过期批次上分配
    /// （评审 S1-1：不按 medication 过滤会把 A 药确认扣到 B 药批；过期批不得作来源）。
    /// nonisolated：在 writer.write 的同步闭包内调用，不触碰 actor 状态。
    private nonisolated func applyResolution(patientId: UUID, medicationId: UUID, notifyId: String, units: Double,
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
        // 确认线分配（仅 taken）；计划线按 FEFO 同样分配（矩阵语义）
        var planRemaining = action == .snoozed ? 0 : units
        var confirmedRemaining = action == .taken ? units : 0
        var allocations: [(lotId: UUID, units: Double)] = []
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
                allocations.append((lot.lotId, confirmedTake))
            }
        }
        for lot in inventories {
            try db.execute(sql: """
                UPDATE stock_lot SET remaining_plan_units = ?, remaining_confirmed_units = ?
                WHERE id = ?
                """, arguments: [lot.remainingPlanUnits, lot.remainingConfirmedUnits, lot.lotId.uuidString])
        }
        for a in allocations where a.units > 0 {
            try db.execute(sql: """
                INSERT INTO dose_lot_allocation (dose_log_id, stock_lot_id, planned_units, confirmed_units)
                VALUES (?, ?, ?, ?)
                """, arguments: [notifyId, a.lotId.uuidString, a.units, a.units])
        }
    }

    public enum StoreError: Error, LocalizedError {
        case doseNotFound(String)
        case alreadyResolved(String)
        case takenMustUseConfirm(String)
        public var errorDescription: String? { "剂量行操作失败: \(self)" }
    }

    // MARK: - 滚动预排窗口（§5.4：只物化未来 7 天，每日对账滚动补排）

    /// 为全部 active 计划物化窗口内剂量行（幂等）。dose_log.plan_id 必须指向真实
    /// 计划——否则 DoseSource.deliveryFacts 的 JOIN 恒空，提醒链断裂。
    /// 评审修正 P0：窗口日界必须以 now 为锚——fromDay 硬编码 1 会让开立超过
    /// 7 天的老计划全部生成在过去被过滤，inserted=0 永不再物化。
    /// 返回本窗口新物化的行数。
    public func materializeWindow(now: Date, calendar: Calendar) async throws -> Int {
        let windowEnd = now.addingTimeInterval(TimeInterval(ReconcileEngine.preScheduleWindowDays * 86400))
        var inserted = 0
        try await writer.write { db in
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
        }
        return inserted
    }

    // MARK: - DoseSource（对账输入）

    public func deliveryFacts(from: Date, to: Date) async throws -> [DoseDeliveryFact] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.id AS dose_id, d.scheduled_for, d.dose_units, d.user_action, d.delivery_state,
                       m.generic_name, m.spec, m.unit_kind
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
                    unitKind: row["unit_kind"] as String?)
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
}
#endif
