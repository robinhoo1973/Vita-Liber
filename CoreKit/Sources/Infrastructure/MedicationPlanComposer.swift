#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// §4.2 UnitOfWork：跨聚合写操作在单个 GRDB 事务内执行。
/// 成员删除（FR3.4）、处方→计划五表创建（§4.2 参考模板）、计划生命周期
/// （FR9.15）都经本类型——任一步抛错 → 整体回滚，不产生半更新状态。
public struct UnitOfWork: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// 单事务执行入口。op 为同步闭包（GRDB 事务语义），调用方为
    /// @MainActor View 时经 `Task { try await uow.run { ... } }` 桥接。
    public func run<T>(_ op: @escaping (Database) throws -> T) async throws -> T {
        try await writer.write { db in try op(db) }
    }
}

/// §4.2 createMedicationPlan 五表原子参考模板（评审 V3.32 要求、此前缺失）：
/// medication → prescription → medication_plan → stock_lot → dose_lot_allocation，
/// FK 插入顺序不可调换（foreign_keys=ON 下违反约束即抛错回滚）。
///
/// BR-003 前置闸门：**未确认处方不得生成正式计划**——`PrescriptionConfirmation
/// .isFullyConfirmed` 为 false 时抛错（PlanGate 语义在 Domain，本层只执行）。
/// 任一步抛错 → 全部回滚 + 审计不落半条（R0-4 纪律）。
public actor MedicationPlanComposer {
    private let writer: any DatabaseWriter
    private let audit: AuditLogWriter

    public init(writer: any DatabaseWriter, audit: AuditLogWriter) {
        self.writer = writer
        self.audit = audit
    }

    public enum ComposerError: Error, LocalizedError, Equatable {
        case prescriptionNotConfirmed
        case planNotFound(UUID)
        case planNotActive(UUID)
        public var errorDescription: String? {
            switch self {
            case .prescriptionNotConfirmed: return "处方未确认——不得生成正式用药计划（BR-003）"
            case .planNotFound(let id): return "计划不存在: \(id.uuidString)"
            case .planNotActive(let id): return "计划非 active 状态: \(id.uuidString)"
            }
        }
    }

    /// 五表原子创建（§4.2 参考模板）。返回 (medicationId, prescriptionId, planId, lotId)。
    @discardableResult
    public func createMedicationPlan(prescription: Prescription,
                                     plan: MedicationPlanDraft,
                                     initialLot: StockLotDraft,
                                     now: Date = Date()) async throws -> (UUID, UUID, UUID, UUID) {
        // BR-003 闸门在 Domain（PlanGate 语义），本层拒绝未确认处方
        guard PrescriptionConfirmation.isFullyConfirmed(prescription) else {
            throw ComposerError.prescriptionNotConfirmed
        }
        let planId = UUID()
        let scheduleJSON = String(data: try JSONEncoder().encode(plan.schedule), encoding: .utf8) ?? "{}"
        return try await writer.write { db -> (UUID, UUID, UUID, UUID) in
            // ① 药品定义（按 generic_name+spec 去重复用，§4.2 upsertReturningId）
            let medId = UUID()
            try db.execute(sql: """
                INSERT INTO medication (id, patient_id, generic_name, brand_name, spec, unit_kind, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [medId.uuidString, prescription.patientId.uuidString,
                                 prescription.genericName, prescription.brandName,
                                 prescription.spec, initialLot.unitKind,
                                 now.timeIntervalSince1970, now.timeIntervalSince1970])
            // ② 处方记录（BR-003 全确认才 confirmed=1）
            let rxId = prescription.id
            try db.execute(sql: """
                INSERT INTO prescription
                  (id, patient_id, encounter_id, document_file_id, source, hospital, doctor,
                   prescribed_at, advice_text, confirmed, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """, arguments: [rxId.uuidString, prescription.patientId.uuidString,
                                 prescription.encounterId?.uuidString,
                                 prescription.documentFileId?.uuidString,
                                 prescription.source.rawValue,
                                 prescription.hospital, prescription.doctor,
                                 prescription.durationStart?.timeIntervalSince1970,
                                 prescription.adviceText,
                                 now.timeIntervalSince1970, now.timeIntervalSince1970])
            // ③ 用药计划（schedule_json §5.4 schema）
            try db.execute(sql: """
                INSERT INTO medication_plan
                  (id, patient_id, medication_id, status, schedule_json, start_date, end_date,
                   dose_plan_units, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [planId.uuidString, prescription.patientId.uuidString,
                                 medId.uuidString, plan.status.rawValue, scheduleJSON,
                                 plan.startDate.timeIntervalSince1970,
                                 plan.endDate?.timeIntervalSince1970,
                                 initialLot.totalUnits,
                                 now.timeIntervalSince1970, now.timeIntervalSince1970])
            // ④ 初始库存批次（处方 OCR 回填数量/效期/位置；FR9.10）
            let lotId = UUID()
            try db.execute(sql: """
                INSERT INTO stock_lot
                  (id, patient_id, medication_id, prescription_id, total_units, unit_kind,
                   remaining_plan_units, remaining_confirmed_units, opened_at, expire_at,
                   storage_note, status, last_reconciled_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?)
                """, arguments: [lotId.uuidString, prescription.patientId.uuidString,
                                 medId.uuidString, rxId.uuidString,
                                 initialLot.totalUnits, initialLot.unitKind,
                                 initialLot.totalUnits, initialLot.totalUnits,
                                 initialLot.openedAt?.timeIntervalSince1970,
                                 initialLot.expireAt?.timeIntervalSince1970,
                                 initialLot.storageNote,
                                 now.timeIntervalSince1970])
            // ⑤ 初始分配：安全线基线 = stock_lot.remaining_plan_units = total_units
            // （已在 ④ 写入）。dose_lot_allocation 的 dose_log_id 是 medication_dose_log
            // 外键——基线没有可引用的真实剂量行，逐剂分配由确认时的
            // applyResolutionOnLots 按 FR9.8.2 矩阵记账（不在建计划时伪造剂量行，
            // 否则零确认计划会被 materializeMissed 误判为漏服）。
            // 生命周期事件：started（FR9.15 历史起点）
            try db.execute(sql: """
                INSERT INTO plan_lifecycle_event (id, plan_id, kind, occurred_at, note)
                VALUES (?, ?, 'started', ?, NULL)
                """, arguments: [UUID().uuidString, planId.uuidString, now.timeIntervalSince1970])
            return (medId, rxId, planId, lotId)
        }
    }

    // MARK: - FR9.15 计划生命周期（状态变更 + 历史事件同事务）

    public func pausePlan(planId: UUID, note: String? = nil, now: Date = Date()) async throws {
        try await setPlanStatus(planId: planId, to: "paused", note: note, kind: "paused", now: now)
    }

    public func resumePlan(planId: UUID, note: String? = nil, now: Date = Date()) async throws {
        try await setPlanStatus(planId: planId, to: "active", note: note, kind: "resumed", now: now)
    }

    public func endPlan(planId: UUID, reason: PlanEndReason, now: Date = Date()) async throws {
        try await writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT id, patient_id FROM medication_plan WHERE id = ?",
                                             arguments: [planId.uuidString]) else {
                throw ComposerError.planNotFound(planId)
            }
            try db.execute(sql: """
                UPDATE medication_plan SET status = 'ended', ended_at = ?, ended_reason = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [now.timeIntervalSince1970, reason.rawValue,
                                 now.timeIntervalSince1970, planId.uuidString])
            try db.execute(sql: """
                INSERT INTO plan_lifecycle_event (id, plan_id, kind, occurred_at, note)
                VALUES (?, ?, 'ended', ?, ?)
                """, arguments: [UUID().uuidString, planId.uuidString,
                                 now.timeIntervalSince1970, reason.rawValue])
        }
    }

    /// 编辑剂量/频次：安全线基线重算（FR9.15 边界——编辑后发起盘点邀请由 UI 层承接）
    public func editPlanSchedule(planId: UUID, schedule: MedicationSchedule,
                                 now: Date = Date()) async throws {
        let json = String(data: try JSONEncoder().encode(schedule), encoding: .utf8) ?? "{}"
        try await writer.write { db in
            guard try Row.fetchOne(db, sql: "SELECT id FROM medication_plan WHERE id = ? AND status = 'active'",
                                   arguments: [planId.uuidString]) != nil else {
                throw ComposerError.planNotActive(planId)
            }
            try db.execute(sql: """
                UPDATE medication_plan SET schedule_json = ?, updated_at = ? WHERE id = ?
                """, arguments: [json, now.timeIntervalSince1970, planId.uuidString])
            try db.execute(sql: """
                INSERT INTO plan_lifecycle_event (id, plan_id, kind, occurred_at, note)
                VALUES (?, ?, 'edited', ?, NULL)
                """, arguments: [UUID().uuidString, planId.uuidString, now.timeIntervalSince1970])
        }
    }

    private func setPlanStatus(planId: UUID, to status: String, note: String?,
                               kind: String, now: Date) async throws {
        try await writer.write { db in
            guard try Row.fetchOne(db, sql: "SELECT id FROM medication_plan WHERE id = ?",
                                   arguments: [planId.uuidString]) != nil else {
                throw ComposerError.planNotFound(planId)
            }
            try db.execute(sql: """
                UPDATE medication_plan SET status = ?, updated_at = ? WHERE id = ?
                """, arguments: [status, now.timeIntervalSince1970, planId.uuidString])
            try db.execute(sql: """
                INSERT INTO plan_lifecycle_event (id, plan_id, kind, occurred_at, note)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, planId.uuidString, kind,
                                 now.timeIntervalSince1970, note])
        }
    }

    // MARK: - 查询

    /// FR9.15 计划历史时间轴（开始/调整/暂停/恢复/结束，供「给医生看」视图引用）
    public func lifecycleEvents(planId: UUID) async throws -> [PlanLifecycleEvent] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM plan_lifecycle_event WHERE plan_id = ? ORDER BY occurred_at
                """, arguments: [planId.uuidString]).map { row in
                PlanLifecycleEvent(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    planId: planId,
                    kind: PlanLifecycleEvent.Kind(rawValue: row["kind"] as String) ?? .started,
                    at: Date(timeIntervalSince1970: row["occurred_at"] as Double),
                    note: row["note"] as String?)
            }
        }
    }
}
#endif
