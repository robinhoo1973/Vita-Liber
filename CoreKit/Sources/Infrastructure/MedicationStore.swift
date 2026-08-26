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

    /// 确认「服了」：写 dose_log + 按 FEFO 扣确认线 + 写 dose_lot_allocation（同事务）
    public func confirmTaken(doseLogId: UUID, patientId: UUID, units: Double) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO medication_dose_log (id, plan_id, scheduled_for, delivery_state, user_action, acted_at)
                VALUES (?, '', ?, 'delivered', 'taken', ?)
                """,
                arguments: [doseLogId.uuidString, Date().timeIntervalSince1970, Date().timeIntervalSince1970])
            // 以库内余量重建双轨 → Domain 矩阵 → 回写（ERR#35：FK 写入禁 IGNORE）
            var inventories: [DualTrackInventory] = []
            for row in try Row.fetchAll(db, sql: """
                SELECT * FROM stock_lot WHERE patient_id = ? AND status = 'active'
                """, arguments: [patientId.uuidString]) {
                var inv = DualTrackInventory(lotId: UUID(uuidString: row["id"] as String) ?? UUID(),
                                             totalUnits: row["total_units"] as Double,
                                             unitKind: row["unit_kind"] as String,
                                             expireAt: (row["expire_at"] as Double?).map { Date(timeIntervalSince1970: $0) })
                inv.remainingPlanUnits = row["remaining_plan_units"] as Double
                inv.remainingConfirmedUnits = row["remaining_confirmed_units"] as Double
                inventories.append(inv)
            }
            let (updated, allocations) = InventoryRules.allocateConfirmed(lots: inventories, units: units)
            for lot in updated {
                try db.execute(sql: """
                    UPDATE stock_lot SET remaining_confirmed_units = ? WHERE id = ?
                    """, arguments: [lot.remainingConfirmedUnits, lot.lotId.uuidString])
            }
            for a in allocations {
                try db.execute(sql: """
                    INSERT INTO dose_lot_allocation (dose_log_id, stock_lot_id, planned_units, confirmed_units)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [doseLogId.uuidString, a.lotId.uuidString, a.units, a.units])
            }
        }
    }

    /// 跳过/忘记/不适：只写动作，双线零扣减（BR-004 纯事实）
    public func recordAction(doseLogId: UUID, action: DoseUserAction) async throws {
        guard action != .taken else { return }   // taken 走 confirmTaken
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO medication_dose_log (id, plan_id, scheduled_for, delivery_state, user_action, acted_at)
                VALUES (?, '', ?, 'delivered', ?, ?)
                """, arguments: [doseLogId.uuidString, Date().timeIntervalSince1970,
                                 action.rawValue, Date().timeIntervalSince1970])
        }
    }

    // MARK: - 滚动预排窗口（§5.4：只物化未来 7 天，每日对账滚动补排）

    /// 为全部 active 计划物化窗口内剂量行（幂等）。dose_log.plan_id 必须指向真实
    /// 计划——否则 DoseSource.deliveryFacts 的 JOIN 恒空，提醒链断裂。
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
                let (doses, _) = DoseScheduleEngine.doses(
                    schedule: schedule, planId: planId, startDate: startDate,
                    fromDay: 1, toDay: ReconcileEngine.preScheduleWindowDays, calendar: calendar)
                for d in doses {
                    guard d.dueAt >= now && d.dueAt <= windowEnd else { continue }
                    if let end = endDate, d.dueAt > end.addingTimeInterval(86400) { continue }   // 到期次日不物化
                    try db.execute(
                        sql: """
                        INSERT INTO medication_dose_log (id, plan_id, scheduled_for, delivery_state, user_action)
                        VALUES (?, ?, ?, 'planned', NULL)
                        ON CONFLICT(id) DO NOTHING
                        """,
                        arguments: [d.notifyId, planId.uuidString, d.dueAt.timeIntervalSince1970])
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
                SELECT d.id AS dose_id, d.scheduled_for, d.user_action, d.delivery_state
                FROM medication_dose_log d
                JOIN medication_plan p ON p.id = d.plan_id
                WHERE p.status = 'active' AND d.scheduled_for >= ? AND d.scheduled_for <= ?
                """, arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970])
            return rows.map { row in
                let scheduledFor = Date(timeIntervalSince1970: row["scheduled_for"] as Double)
                let action = (row["user_action"] as String?).flatMap(DoseUserAction.init(rawValue:))
                return DoseDeliveryFact(
                    dose: ScheduledDose(dueAt: scheduledFor, doseUnits: 1,
                                        notifyId: row["dose_id"] as String),
                    delivered: (row["delivery_state"] as String) == "delivered",
                    action: action,
                    isDueSoon: scheduledFor <= from.addingTimeInterval(30 * 60),
                    isExpiredGrace: scheduledFor < from.addingTimeInterval(-15 * 60))
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
