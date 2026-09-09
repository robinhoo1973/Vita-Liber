#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// FR3.4 删除成员（§5.51 UnitOfWork.deleteMember 语义）：
/// ① 影响清单先行（资料数/计划/提醒/预约计数）；
/// ② 二次确认由 UI 承担（输入成员姓名）；
/// ③ 清除关联资料的归属标记但**不删资料本身**——成员行软删（deleted_at），
///   数据行保留 patient_id，「未归属」筛选 = 该成员的资料；
/// ④ 该成员的用药计划/提醒/预约按用户选择「一并删除」或「停用归档」。
/// 全程单事务（UnitOfWork），任一步失败整体回滚。
public actor MemberDeletionService {
    private let writer: any DatabaseWriter
    /// 通知调度端口（可选注入）：删除成员时取消其预约分级提醒——
    /// 对账引擎只清理 dose-/slot- 前缀，apt- 必须由删除路径显式取消
    /// （否则已删成员/已取消预约的提醒仍按时弹出，隐私与 FR3.4 双违）。
    private let scheduler: (any ReminderScheduling)?

    public init(writer: any DatabaseWriter, scheduler: (any ReminderScheduling)? = nil) {
        self.writer = writer
        self.scheduler = scheduler
    }

    public struct Impact: Sendable, Equatable {
        public var documentCount: Int
        public var observationCount: Int
        public var planCount: Int
        public var appointmentCount: Int
        public var allergyCount: Int
        public init(documentCount: Int = 0, observationCount: Int = 0,
                    planCount: Int = 0, appointmentCount: Int = 0, allergyCount: Int = 0) {
            self.documentCount = documentCount; self.observationCount = observationCount
            self.planCount = planCount; self.appointmentCount = appointmentCount
            self.allergyCount = allergyCount
        }
    }

    public enum DeleteChoice: String, Sendable {
        case deletePlans       // 一并删除计划/提醒/预约
        case archivePlans      // 停用归档（计划置 paused）
    }

    /// 影响清单（FR3.4：删除前展示）
    public func impact(patientId: UUID) async throws -> Impact {
        try await writer.read { db in
            func count(_ table: String) throws -> Int {
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE patient_id = ?",
                                   arguments: [patientId.uuidString])) ?? 0
            }
            var imp = Impact()
            imp.documentCount = try count("document_file")
            imp.observationCount = try count("observation")
            imp.planCount = try count("medication_plan")
            imp.appointmentCount = try count("appointment")
            imp.allergyCount = try count("allergy_event")
            return imp
        }
    }

    /// 删除成员（单事务）。注意：document/observation/allergy 保留（不删资料），
    /// 归属标记由软删的成员行承载（「未归属」筛选语义）。
    public func deleteMember(patientId: UUID, choice: DeleteChoice,
                             now: Date = Date()) async throws {
        let notificationIds = try await writer.write { db -> ([String], [String]) in
            guard try Row.fetchOne(db, sql: "SELECT id FROM patient_profile WHERE id = ? AND deleted_at IS NULL",
                                   arguments: [patientId.uuidString]) != nil else {
                throw StoreError.memberNotFound(patientId)
            }
            // 本人档案拒绝删除（纵深防御：与视图层闸门双保险——见 StoreError 注）
            if let selfId = try String.fetchOne(db, sql: "SELECT self_patient_id FROM local_owner LIMIT 1"),
               selfId == patientId.uuidString {
                throw StoreError.cannotDeleteSelf
            }
            let aptIds = try String.fetchAll(db, sql: "SELECT id FROM appointment WHERE patient_id = ? AND status = 'scheduled'",
                                             arguments: [patientId.uuidString])
            let pendingIds = try String.fetchAll(db, sql: "SELECT id FROM pending_card WHERE patient_id = ?",
                                                 arguments: [patientId.uuidString])
            try db.execute(sql: """
                UPDATE pending_card SET status = 'archived', updated_at = ?, note = 'member_deleted'
                WHERE patient_id = ? AND status IN ('pending','in_progress','expired')
                """, arguments: [now.timeIntervalSince1970, patientId.uuidString])
            switch choice {
            case .deletePlans:
                // 拓扑序清理（FK 开启，REFERENCES 目标必须先行）：
                // dose_lot_allocation → notification_delivery(dose_log_id) →
                // medication_dose_log → plan_lifecycle_event → stock_lot →
                // medication_plan → reminder/appointment
                // 审查修复：原序漏删 plan_lifecycle_event 与 notification_delivery——
                // DELETE medication_plan/dose_log 时外键违约整事务回滚，成员删不掉。
                try db.execute(sql: """
                    DELETE FROM dose_lot_allocation WHERE stock_lot_id IN
                      (SELECT id FROM stock_lot WHERE patient_id = ?)
                    """, arguments: [patientId.uuidString])
                try db.execute(sql: """
                    DELETE FROM notification_delivery WHERE dose_log_id IN
                      (SELECT id FROM medication_dose_log WHERE plan_id IN
                        (SELECT id FROM medication_plan WHERE patient_id = ?))
                    """, arguments: [patientId.uuidString])
                try db.execute(sql: """
                    DELETE FROM medication_dose_log WHERE plan_id IN
                      (SELECT id FROM medication_plan WHERE patient_id = ?)
                    """, arguments: [patientId.uuidString])
                try db.execute(sql: """
                    DELETE FROM plan_lifecycle_event WHERE plan_id IN
                      (SELECT id FROM medication_plan WHERE patient_id = ?)
                    """, arguments: [patientId.uuidString])
                try db.execute(sql: "DELETE FROM stock_lot WHERE patient_id = ?",
                               arguments: [patientId.uuidString])
                try db.execute(sql: "DELETE FROM medication_plan WHERE patient_id = ?",
                               arguments: [patientId.uuidString])
                try db.execute(sql: "DELETE FROM reminder WHERE patient_id = ?",
                               arguments: [patientId.uuidString])
                try db.execute(sql: "DELETE FROM appointment WHERE patient_id = ?",
                               arguments: [patientId.uuidString])
            case .archivePlans:
                // 停用归档：计划置 paused（不生成提醒、双轨扣减冻结，FR9.15 语义）
                try db.execute(sql: """
                    UPDATE medication_plan SET status = 'paused', updated_at = ? WHERE patient_id = ? AND status = 'active'
                    """, arguments: [now.timeIntervalSince1970, patientId.uuidString])
                try db.execute(sql: """
                    UPDATE appointment SET status = 'cancelled', cancel_reason = 'member_deleted', updated_at = ?
                    WHERE patient_id = ? AND status = 'scheduled'
                    """, arguments: [now.timeIntervalSince1970, patientId.uuidString])
            }
            // 软删成员行（资料保留，归属标记清除语义）
            try db.execute(sql: "UPDATE patient_profile SET deleted_at = ? WHERE id = ?",
                           arguments: [now.timeIntervalSince1970, patientId.uuidString])
            return (aptIds, pendingIds)
        }
        // 写事务成功后才取消系统侧通知：删除/取消的预约不再按时弹出提醒
        if let scheduler {
            // Cancel OCR requests first, even when there were no appointments.
            if !notificationIds.1.isEmpty {
                do { try await scheduler.cancel(notificationIds.1.map { "pending-\($0)" }) }
                catch { throw StoreError.pendingNotificationCancellationFailed }
            }
            let pending = try await scheduler.pending()
            let stale = ReminderIDNames.staleAppointments(in: pending, ids: notificationIds.0)
            if !stale.isEmpty {
                try await scheduler.cancel(Array(stale))
            }
        }
    }

    /// Retry OS cancellation after an already committed soft deletion.
    public func retryPendingNotificationCancellation(patientId: UUID) async throws {
        guard let scheduler else { throw StoreError.schedulerUnavailable }
        let ids = try await writer.read { db in
            try String.fetchAll(db, sql: "SELECT p.id FROM pending_card p JOIN patient_profile m ON m.id = p.patient_id WHERE p.patient_id = ? AND m.deleted_at IS NOT NULL",
                                arguments: [patientId.uuidString])
        }
        if !ids.isEmpty { try await scheduler.cancel(ids.map { "pending-\($0)" }) }
    }

    /// FR3.5 重新归属：把资料移给另一成员（留审计由调用方记）
    public func reattributeDocument(documentId: UUID, from: UUID, to: UUID,
                                    now: Date = Date()) async throws {
        try await writer.write { db in
            guard try Row.fetchOne(db, sql: "SELECT id FROM patient_profile WHERE id = ? AND deleted_at IS NULL",
                                   arguments: [to.uuidString]) != nil else {
                throw StoreError.memberNotFound(to)
            }
            if from != to, try Self.hasRetainedOCRLinks(documentId: documentId, db: db) {
                throw StoreError.incompatibleOCRSource
            }
            try db.execute(sql: """
                UPDATE document_file SET patient_id = ?, updated_at = ? WHERE id = ? AND patient_id = ?
                """, arguments: [to.uuidString, now.timeIntervalSince1970,
                                 documentId.uuidString, from.uuidString])
            guard db.changesCount > 0 else { throw StoreError.documentNotFound(documentId) }
        }
    }

    static func hasRetainedOCRLinks(documentId: UUID, db: Database) throws -> Bool {
        let document = documentId.uuidString
        return try Int.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM pending_card WHERE source_doc_id = ?)
              OR EXISTS(SELECT 1 FROM ocr_card_commit WHERE document_file_id = ?)
              OR EXISTS(SELECT 1 FROM metric_sample WHERE source_ref = ? OR source_ref LIKE ?)
              OR EXISTS(SELECT 1 FROM prescription WHERE document_file_id = ?)
              OR EXISTS(SELECT 1 FROM document_file WHERE id = ? AND encounter_id IS NOT NULL)
            """, arguments: [document, document, "doc:\(document)", "doc:\(document)#p%", document, document]) == 1
    }

    public enum StoreError: Error, LocalizedError {
        case memberNotFound(UUID)
        case documentNotFound(UUID)
        case incompatibleOCRSource, schedulerUnavailable, pendingNotificationCancellationFailed
        /// 审查修复（本人删除纵深防御）：视图层 owner 未装载时闸门失效——
        /// 本服务在事务内二次校验，拒绝删除 local_owner.self_patient_id 指向的
        /// 本人档案（BR-001 锚点：本人档案是当前成员回落目标，删除即锚点
        /// 落到软删行）。UI 外的任何调用路径同样被拦。
        case cannotDeleteSelf
        public var errorDescription: String? {
            switch self {
            case .incompatibleOCRSource: return "Document has retained OCR facts or drafts; reassignment refused."
            case .schedulerUnavailable: return "Reminder scheduler is required to cancel pending OCR notifications."
            case .pendingNotificationCancellationFailed: return "Member deletion committed; retry pending OCR notification cancellation."
            case .cannotDeleteSelf: return "本人档案不可删除（BR-001 锚点保护）"
            default: return "删除/归属操作目标不存在: \(self)"
            }
        }
    }
}
#endif
