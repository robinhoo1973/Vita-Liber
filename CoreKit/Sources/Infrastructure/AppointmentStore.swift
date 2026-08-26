#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F10 预约数据仓（actor）：创建/改期/取消 + 分级提醒（FR10.3）+ 状态机（FR10.7）
public actor AppointmentStore {
    private let writer: any DatabaseWriter
    private let scheduler: any ReminderScheduling

    public init(writer: any DatabaseWriter, scheduler: any ReminderScheduling) {
        self.writer = writer
        self.scheduler = scheduler
    }

    /// 创建预约 + 反算四级触发点预排（§5.4 V3.31；已过期层级不补发）
    public func create(id: UUID = UUID(), patientId: UUID, hospital: String,
                       department: String, startsAt: Date, tiers: [AppointmentTier] = AppointmentTier.defaults,
                       now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO appointment (id, patient_id, hospital, department, starts_at, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'scheduled', ?, ?)
                """,
                arguments: [id.uuidString, patientId.uuidString, hospital, department,
                            startsAt.timeIntervalSince1970,
                            now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
        for (tier, fire) in AppointmentRules.tierFireDates(startsAt: startsAt, tiers: tiers, now: now) {
            try await scheduler.schedule(dose: "apt-\(id.uuidString)-\(tier.label)", at: fire)
        }
    }

    /// 改期 = 取消全部旧 tiers → 重排新 tiers（幂等，§5.4）
    public func reschedule(id: UUID, startsAt: Date, now: Date = Date()) async throws {
        try await cancelReminders(id: id)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE appointment SET starts_at = ?, updated_at = ? WHERE id = ?",
                arguments: [startsAt.timeIntervalSince1970, now.timeIntervalSince1970, id.uuidString])
        }
        for (tier, fire) in AppointmentRules.tierFireDates(startsAt: startsAt, tiers: AppointmentTier.defaults, now: now) {
            try await scheduler.schedule(dose: "apt-\(id.uuidString)-\(tier.label)", at: fire)
        }
    }

    /// 取消预约：状态机 cancelled + 移除全部 pending（FR10.7）
    public func cancel(id: UUID, now: Date = Date()) async throws {
        try await cancelReminders(id: id)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE appointment SET status = 'cancelled', updated_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, id.uuidString])
        }
    }

    /// 标记完成（FR10.7：completed）
    public func complete(id: UUID, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE appointment SET status = 'completed', updated_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, id.uuidString])
        }
    }

    private func cancelReminders(id: UUID) async throws {
        let pending = try await scheduler.pending()
        let ids = pending.keys.filter { $0.hasPrefix("apt-\(id.uuidString)") }
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
                    hospital: row["hospital"] as String,
                    department: (row["department"] as String?) ?? "",
                    startsAt: Date(timeIntervalSince1970: row["starts_at"] as Double),
                    status: row["status"] as String)
            }
        }
    }
}

public struct AppointmentRow: Sendable, Equatable {
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
