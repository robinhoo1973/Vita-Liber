#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F10 预约数据仓（actor）：创建/改期/取消 + 分级提醒（FR10.3）+ 状态机（FR10.7）
public actor AppointmentStore {
    /// 审查修复新增：目标不存在时抛错（§7 不得静默 return）
    public enum StoreError: Error, Equatable { case notFound }

    private let writer: any DatabaseWriter
    private let scheduler: any ReminderScheduling

    public init(writer: any DatabaseWriter, scheduler: any ReminderScheduling) {
        self.writer = writer
        self.scheduler = scheduler
    }

    /// 创建预约 + 反算四级触发点预排（§5.4 V3.31；已过期层级不补发）。
    /// 返回预约 id（调用方据此排复诊提醒）。
    @discardableResult
    public func create(id: UUID = UUID(), patientId: UUID, hospital: String,
                       department: String, startsAt: Date,
                       doctor: String? = nil, address: String? = nil,
                       itemsToBring: String? = nil, notes: String? = nil,
                       tiers: [AppointmentTier] = AppointmentTier.defaults,
                       now: Date = Date()) async throws -> UUID {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO appointment (id, patient_id, hospital, department, doctor, address,
                                         items_to_bring, notes, starts_at, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'scheduled', ?, ?)
                """,
                arguments: [id.uuidString, patientId.uuidString, hospital, department,
                            doctor, address, itemsToBring, notes,
                            startsAt.timeIntervalSince1970,
                            now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
        for (tier, fire) in AppointmentRules.tierFireDates(startsAt: startsAt, tiers: tiers, now: now) {
            try await scheduler.schedule(dose: "apt-\(id.uuidString)-\(tier.label)", at: fire,
                                         route: .appointmentList)
        }
        return id
    }

    /// 改期（FR10.7）：**原预约保留历史**（status='cancelled' + cancel_reason=
    /// 'rescheduled'）+ 生成新草稿（rescheduled_from_id 回指原预约），
    /// 新草稿重排四级提醒——改期不是原地 UPDATE（历史可溯）。
    @discardableResult
    public func reschedule(id: UUID, startsAt: Date, now: Date = Date()) async throws -> UUID {
        let newId = UUID()
        try await writer.write { db in
            // 审查修复（§7 不得静默 return）：目标不存在时抛错——原实现
            // 静默返回一个无对应行的 newId，上层以为改期成功，四级提醒
            // 被排到不存在的预约上（与 MedicationStore.recordAction 对齐）
            guard let old = try Row.fetchOne(db, sql: "SELECT * FROM appointment WHERE id = ?",
                                             arguments: [id.uuidString]) else {
                throw StoreError.notFound
            }
            try db.execute(
                sql: "UPDATE appointment SET status = 'cancelled', cancel_reason = 'rescheduled', updated_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, id.uuidString])
            try db.execute(
                sql: """
                INSERT INTO appointment (id, patient_id, hospital, department, starts_at, status,
                                         rescheduled_from, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'scheduled', ?, ?, ?)
                """,
                arguments: [newId.uuidString, old["patient_id"] as String,
                            (old["hospital"] as String?) ?? "", (old["department"] as String?) ?? "",
                            startsAt.timeIntervalSince1970, id.uuidString,
                            now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
        // 审查修复：取消旧提醒移到写事务成功之后——原顺序先取消后校验，
        // 写失败（notFound）时预约仍在 scheduled 态但提醒已被移除且对账
        // 不复排 apt- 通知，留下永不再提醒的预约
        try await cancelReminders(id: id)
        for (tier, fire) in AppointmentRules.tierFireDates(startsAt: startsAt, tiers: AppointmentTier.defaults, now: now) {
            try await scheduler.schedule(dose: "apt-\(newId.uuidString)-\(tier.label)", at: fire,
                                         route: .appointmentList)
        }
        return newId
    }

    /// 取消预约：状态机 cancelled + 选填原因 + 移除全部 pending（FR10.7）
    public func cancel(id: UUID, reason: String? = nil, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE appointment SET status = 'cancelled', cancel_reason = ?, updated_at = ? WHERE id = ?",
                arguments: [reason, now.timeIntervalSince1970, id.uuidString])
        }
        // 写成功后才取消提醒（同 reschedule/complete 的次序纪律）
        try await cancelReminders(id: id)
    }

    /// 标记「错过」（FR10.7）：missed + 触发跟进提醒（FR10.3 错过跟进）
    public func markMissed(id: UUID, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE appointment SET status = 'missed', updated_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, id.uuidString])
        }
        // 跟进提醒：错过当天稍后提醒补录（复用分级通道，route=预约列表）
        let followUpAt = now.addingTimeInterval(2 * 3600)
        try await scheduler.schedule(dose: "apt-followup-\(id.uuidString)", at: followUpAt,
                                     route: .appointmentList)
    }

    /// 标记完成（FR10.7：completed）+ 补录就诊（评审修正 P0：闭环断点——
    /// 「标记完成→补录就诊」此前只改状态无 encounter 写入）
    public func complete(id: UUID, now: Date = Date()) async throws {
        try await writer.write { db in
            // 审查修复（§7 不得静默 return）：同 reschedule
            guard let apt = try Row.fetchOne(db, sql: "SELECT * FROM appointment WHERE id = ?",
                                             arguments: [id.uuidString]) else {
                throw StoreError.notFound
            }
            try db.execute(
                sql: "UPDATE appointment SET status = 'completed', updated_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, id.uuidString])
            // 懒建就诊（F4）：以预约信息落 encounter 行，kind=复诊
            try db.execute(
                sql: """
                INSERT INTO encounter (id, patient_id, date, kind, created_at, updated_at)
                VALUES (?, ?, ?, '复诊', ?, ?)
                """,
                arguments: [UUID().uuidString, apt["patient_id"] as String,
                            apt["starts_at"] as Double, now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
        // 审查修复：写成功后才取消提醒（先取消后校验的旧序见 reschedule 注释）
        try await cancelReminders(id: id)
    }

    private func cancelReminders(id: UUID) async throws {
        let pending = try await scheduler.pending()
        let ids = pending.keys.filter { $0.hasPrefix(ReminderIDNames.appointmentPrefix(id)) }
        try await scheduler.cancel(Array(ids))
    }

    /// 预约列表投影
    public func upcoming(patientId: UUID, now: Date = Date()) async throws -> [AppointmentRow] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM appointment
                WHERE patient_id = ? AND status = 'scheduled' AND starts_at >= ?
                ORDER BY starts_at
                """, arguments: [patientId.uuidString, now.timeIntervalSince1970])
            .map { row in
                AppointmentRow(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    hospital: (row["hospital"] as String?) ?? "",
                    department: (row["department"] as String?) ?? "",
                    startsAt: Date(timeIntervalSince1970: row["starts_at"] as Double),
                    status: row["status"] as String)
            }
        }
    }

    /// FR10.7 状态机历史（SP-18 四态分段：待就诊/已完成/已取消/错过）
    public func history(patientId: UUID, limit: Int = 100) async throws -> [AppointmentRow] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM appointment
                WHERE patient_id = ?
                ORDER BY starts_at DESC LIMIT ?
                """, arguments: [patientId.uuidString, limit])
            .map { row in
                AppointmentRow(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    hospital: (row["hospital"] as String?) ?? "",
                    department: (row["department"] as String?) ?? "",
                    startsAt: Date(timeIntervalSince1970: row["starts_at"] as Double),
                    status: row["status"] as String)
            }
        }
    }
}

public struct AppointmentRow: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var hospital: String
    public var department: String
    public var startsAt: Date
    public var status: String
    public init(id: UUID, hospital: String, department: String, startsAt: Date, status: String) {
        self.id = id; self.hospital = hospital; self.department = department
        self.startsAt = startsAt; self.status = status
    }
}
#endif
