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

    public init(writer: any DatabaseWriter) { self.writer = writer }

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
        try await writer.write { db in
            guard try Row.fetchOne(db, sql: "SELECT id FROM patient_profile WHERE id = ? AND deleted_at IS NULL",
                                   arguments: [patientId.uuidString]) != nil else {
                throw StoreError.memberNotFound(patientId)
            }
            switch choice {
            case .deletePlans:
                // 拓扑序清理：dose_lot_allocation → medication_dose_log → stock_lot → plan
                try db.execute(sql: """
                    DELETE FROM dose_lot_allocation WHERE stock_lot_id IN
                      (SELECT id FROM stock_lot WHERE patient_id = ?)
                    """, arguments: [patientId.uuidString])
                try db.execute(sql: """
                    DELETE FROM medication_dose_log WHERE plan_id IN
                      (SELECT id FROM medication_plan WHERE patient_id = ?)
                    """, arguments: [patientId.uuidString])
                try db.execute(sql: "DELETE FROM stock_lot WHERE patient_id = ?",
                               arguments: [patientId.uuidString])
                try db.execute(sql: "DELETE FROM medication_plan WHERE patient_id = ?",
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
        }
    }

    /// FR3.5 重新归属：把资料移给另一成员（留审计由调用方记）
    public func reattributeDocument(documentId: UUID, from: UUID, to: UUID,
                                    now: Date = Date()) async throws {
        try await writer.write { db in
            guard try Row.fetchOne(db, sql: "SELECT id FROM patient_profile WHERE id = ? AND deleted_at IS NULL",
                                   arguments: [to.uuidString]) != nil else {
                throw StoreError.memberNotFound(to)
            }
            try db.execute(sql: """
                UPDATE document_file SET patient_id = ?, updated_at = ? WHERE id = ? AND patient_id = ?
                """, arguments: [to.uuidString, now.timeIntervalSince1970,
                                 documentId.uuidString, from.uuidString])
            guard db.changesCount > 0 else { throw StoreError.documentNotFound(documentId) }
        }
    }

    public enum StoreError: Error, LocalizedError {
        case memberNotFound(UUID)
        case documentNotFound(UUID)
        public var errorDescription: String? { "删除/归属操作目标不存在: \(self)" }
    }
}
#endif
