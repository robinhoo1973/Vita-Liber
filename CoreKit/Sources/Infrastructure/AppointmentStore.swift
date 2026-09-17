#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F10 预约数据仓（actor）：创建/改期/取消 + 分级提醒（FR10.3）+ 状态机（FR10.7）
public actor AppointmentStore {
    /// 审查修复新增：目标不存在时抛错（§7 不得静默 return）。
    /// v27：`invalidEncounter` = 挂接目标就诊不存在 / 已软删 / 属于其他成员（BR-001，不区分三者、不泄露存在性）。
    public enum StoreError: Error, Equatable { case notFound, invalidState, invalidEncounter }

    private let writer: any DatabaseWriter
    private let scheduler: any ReminderScheduling

    public init(writer: any DatabaseWriter, scheduler: any ReminderScheduling) {
        self.writer = writer
        self.scheduler = scheduler
    }

    /// 创建预约 + 反算四级触发点预排（§5.4 V3.31；已过期层级不补发）。
    /// 返回预约 id（调用方据此排复诊提醒）。
    /// v27（FR10.7 / round1 §E.1）：`encounterId` = 产生本预约的就诊（复诊预约挂就诊主卡；须同成员、未软删，否则 `invalidEncounter`），
    /// `purpose` = 预约目的（CHECK 枚举 canonical raw）。两参数缺省 nil，既有调用零改动。
    @discardableResult
    public func create(id: UUID = UUID(), patientId: UUID, hospital: String,
                       department: String, startsAt: Date,
                       doctor: String? = nil, address: String? = nil,
                       itemsToBring: String? = nil, notes: String? = nil,
                       encounterId: UUID? = nil, purpose: AppointmentPurpose? = nil,
                       tiers: [AppointmentTier] = AppointmentTier.defaults,
                       now: Date = Date()) async throws -> UUID {
        try await writer.write { db in
            if let encounterId {
                try Self.assertEncounter(encounterId, belongsTo: patientId, db: db)
            }
            try db.execute(
                sql: """
                INSERT INTO appointment (id, patient_id, hospital, department, doctor, address,
                                         items_to_bring, notes, starts_at, status, created_at, updated_at,
                                         encounter_id, purpose)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'scheduled', ?, ?, ?, ?)
                """,
                arguments: [id.uuidString, patientId.uuidString, hospital, department,
                            doctor, address, itemsToBring, notes,
                            startsAt.timeIntervalSince1970,
                            now.timeIntervalSince1970, now.timeIntervalSince1970,
                            encounterId?.uuidString, purpose?.rawValue])
        }
        for (tier, fire) in AppointmentRules.tierFireDates(startsAt: startsAt, tiers: tiers, now: now) {
            try await scheduler.schedule(dose: "apt-\(id.uuidString)-\(tier.label)", at: fire,
                                         route: .appointmentDetail(id))
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
            // 全字段复制（v8 迁移补全列集）：此前只复制 hospital/department/
            // starts_at——doctor/address/items_to_bring/notes 在新草稿中静默
            // 丢失，旧行已置 cancelled，活跃视图再取不到医生地址与需带资料
            // （FR10.6/10.7 支撑列全丢）
            try db.execute(
                sql: """
                INSERT INTO appointment (id, patient_id, hospital, department, starts_at, status,
                                         doctor, address, items_to_bring, notes, source, booking_no,
                                         rescheduled_from, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'scheduled', ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [newId.uuidString, old["patient_id"] as String,
                            (old["hospital"] as String?) ?? "", (old["department"] as String?) ?? "",
                            startsAt.timeIntervalSince1970,
                            (old["doctor"] as String?) ?? "", (old["address"] as String?) ?? "",
                            (old["items_to_bring"] as String?) ?? "", (old["notes"] as String?) ?? "",
                            (old["source"] as String?) ?? "", (old["booking_no"] as String?) ?? "",
                            id.uuidString, now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
        // 审查修复：取消旧提醒移到写事务成功之后——原顺序先取消后校验，
        // 写失败（notFound）时预约仍在 scheduled 态但提醒已被移除且对账
        // 不复排 apt- 通知，留下永不再提醒的预约
        try await cancelReminders(id: id)
        for (tier, fire) in AppointmentRules.tierFireDates(startsAt: startsAt, tiers: AppointmentTier.defaults, now: now) {
            // 第六轮全仓审查修复：route 必须指向改期后的新行——原实现带
            // 原预约 id，通知点击直达一张已取消的旧预约卡（改期后主流程
            // 深层断链）
            try await scheduler.schedule(dose: "apt-\(newId.uuidString)-\(tier.label)", at: fire,
                                         route: .appointmentDetail(newId))
        }
        return newId
    }

    /// 取消预约：状态机 cancelled + 选填原因 + 移除全部 pending（FR10.7）
    public func cancel(id: UUID, reason: String? = nil, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE appointment SET status = 'cancelled', cancel_reason = ?, updated_at = ? WHERE id = ?",
                arguments: [reason, now.timeIntervalSince1970, id.uuidString])
            // 审查修复（响亮拒绝纪律）：目标不存在时 0 行 UPDATE 静默成功，
            // 界面当作取消成功、预约仍在列表——与 DocumentStore 守卫同口径。
            guard db.changesCount == 1 else { throw StoreError.notFound }
        }
        // 写成功后才取消提醒（同 reschedule/complete 的次序纪律）
        try await cancelReminders(id: id)
    }

    /// 标记「错过」（FR10.7）：missed + 触发跟进提醒（FR10.3 错过跟进）
    public func markMissed(id: UUID, now: Date = Date()) async throws {
        try await writer.write { db in
            // 纵深防御：时间门槛在视图层之外再查一次（Domain 单一事实源
            // AppointmentRules.canMarkMissed）——任何新入口绕过视图即可误标
            // 未来预约，取消全部分级提醒并武装 2h 跟进（Domain 规则自述的
            // 失效形态）。复用 notFound 语义拒绝，不泄露状态。
            guard let startsAt = try Double.fetchOne(db, sql: """
                SELECT starts_at FROM appointment WHERE id = ?
                """, arguments: [id.uuidString]) else {
                throw StoreError.notFound
            }
            guard AppointmentRules.canMarkMissed(startsAt: Date(timeIntervalSince1970: startsAt),
                                                 now: now) else {
                throw StoreError.notFound
            }
            try db.execute(
                sql: "UPDATE appointment SET status = 'missed', updated_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, id.uuidString])
        }
        // 第八轮全仓审查修复：标记错过此前不取消已排的**分级提醒**（7d/3d/1d/day
        // 四档）——用户在到期前点「错过」（按钮无时间门槛），后续档位仍按时
        // 弹出并指向一张已错过的预约。写成功后先取消该预约全部 pending 提醒
        // （与 reschedule/cancel/complete 同款次序纪律），再排跟进提醒。
        try await cancelReminders(id: id)
        // 跟进提醒：错过当天稍后提醒补录（复用分级通道，route=预约列表）
        let followUpAt = now.addingTimeInterval(2 * 3600)
        try await scheduler.schedule(dose: "apt-followup-\(id.uuidString)", at: followUpAt,
                                     route: .appointmentDetail(id))
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
            // 审查修复（FR10.7 状态机）：完成无状态守卫——重复调用重复建就诊、
            // 「已完成」覆盖「已错过」抹掉历史状态。仅 scheduled 可完成。
            guard (apt["status"] as String?) == "scheduled" else {
                throw StoreError.invalidState
            }
            // 审查修复（与 markMissed 同口径纵深防御）：时间门槛在视图层之外
            // 再查一次——任何新入口绕过视图即可一触完成未来预约（分级提醒
            // 全取消 + 未来日期复诊就诊落库，BR-004 历史造假）。复用 notFound
            // 语义拒绝，不泄露状态。
            guard AppointmentRules.canMarkCompleted(
                startsAt: Date(timeIntervalSince1970: apt["starts_at"] as Double),
                now: now) else {
                throw StoreError.notFound
            }
            try db.execute(
                sql: "UPDATE appointment SET status = 'completed', updated_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, id.uuidString])
            // 懒建就诊（F4）：以预约信息落 encounter 行，kind=复诊。
            // v27（FR10.7「已完成 → 补录就诊」）：医院/科室/医生随预约带入，并把新就诊回写 appointment.encounter_id
            //（预约与其补录的就诊互达；purpose 缺省 'visit'），时间轴主卡即可把这次预约收为子卡。
            let encounterId = UUID()
            try db.execute(
                sql: """
                INSERT INTO encounter (id, patient_id, date, kind, hospital, department, doctor, created_at, updated_at)
                VALUES (?, ?, ?, '复诊', ?, ?, ?, ?, ?)
                """,
                arguments: [encounterId.uuidString, apt["patient_id"] as String,
                            apt["starts_at"] as Double, apt["hospital"] as String?, apt["department"] as String?, apt["doctor"] as String?,
                            now.timeIntervalSince1970, now.timeIntervalSince1970])
            try db.execute(
                sql: "UPDATE appointment SET encounter_id = ?, purpose = COALESCE(purpose, 'visit') WHERE id = ?",
                arguments: [encounterId.uuidString, id.uuidString])
        }
        // 审查修复：写成功后才取消提醒（先取消后校验的旧序见 reschedule 注释）
        try await cancelReminders(id: id)
    }

    private func cancelReminders(id: UUID) async throws {
        let pending = try await scheduler.pending()
        // 第六轮全仓审查修复：错过跟进提醒（apt-followup-{id}）此前不在
        // 前缀过滤内——完成/取消/改期后跟进提醒仍会在 2h 后为一个已结束
        // 的预约响起。
        // 第七轮全仓审查修复：复诊提醒 `followup-apt-{id}`（ReminderStore.
        // createAppointment 排程）此前同样漏网——取消/改期/完成后原复诊
        // 提醒照常触发并深链到已取消的历史行
        let ids = pending.keys.filter {
            $0.hasPrefix(ReminderIDNames.appointmentPrefix(id))
            || $0.hasPrefix("apt-followup-\(id.uuidString)")
            || $0.hasPrefix("followup-apt-\(id.uuidString)")
        }
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
            .map(Self.appointmentRow)
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
            .map(Self.appointmentRow)
        }
    }

    // MARK: - v27 预约 ↔ 就诊挂接（FR10.7 / round1 §E.1）

    /// 显式挂接：把预约挂到产生它的就诊（用户在就诊页 / 预约详情显式选择；不自动猜）。
    /// 就诊须同成员、未软删（否则 `invalidEncounter`）；`purpose` 非 nil 时覆盖，nil 时保留既有值、缺省 'visit'；
    /// 预约不存在 / 不属于该成员 → 零行更新 → `notFound`（§7 不得静默 return）。
    public func link(appointmentId: UUID, encounterId: UUID, purpose: AppointmentPurpose? = nil,
                     patientId: UUID, now: Date = Date()) async throws {
        try await writer.write { db in
            try Self.assertEncounter(encounterId, belongsTo: patientId, db: db)
            try db.execute(sql: """
                UPDATE appointment SET encounter_id = ?, purpose = COALESCE(?, purpose, 'visit'), updated_at = ?
                WHERE id = ? AND patient_id = ?
                """, arguments: [encounterId.uuidString, purpose?.rawValue, now.timeIntervalSince1970,
                                 appointmentId.uuidString, patientId.uuidString])
            guard db.changesCount == 1 else { throw StoreError.notFound }
            let meta = String(decoding: try JSONEncoder().encode(["relationship": "encounter", "linked": "true"]), as: UTF8.self)
            try AuditLogWriter.insert(action: "update", entityType: "appointment", entityId: appointmentId.uuidString,
                                      actorLocal: "owner", meta: meta, db: db)
        }
    }

    /// 解除挂接（预约保留，只清 encounter_id）；零行 → `notFound`。
    public func unlink(appointmentId: UUID, patientId: UUID, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE appointment SET encounter_id = NULL, updated_at = ? WHERE id = ? AND patient_id = ?",
                           arguments: [now.timeIntervalSince1970, appointmentId.uuidString, patientId.uuidString])
            guard db.changesCount == 1 else { throw StoreError.notFound }
            try AuditLogWriter.insert(action: "update", entityType: "appointment", entityId: appointmentId.uuidString,
                                      actorLocal: "owner", meta: #"{"relationship":"encounter","linked":"false"}"#, db: db)
        }
    }

    /// 可挂接候选（供就诊页「挂接既有预约」Picker）：同成员、尚未挂接、就诊日 ±3 天内；就诊有医院时还须医院同名。
    /// 只是候选清单，挂接必须经用户显式 `link`（不自动生效，FR4.2 同纪律）。
    public func candidates(forEncounter encounterId: UUID, patientId: UUID, dayWindow: Int = 3) async throws -> [AppointmentRow] {
        try await writer.read { db in
            guard let encounter = try Row.fetchOne(db, sql: "SELECT date, hospital FROM encounter WHERE id = ? AND patient_id = ? AND deleted_at IS NULL",
                                                   arguments: [encounterId.uuidString, patientId.uuidString]) else { throw StoreError.invalidEncounter }
            let date: Double = encounter["date"]
            let hospital = (encounter["hospital"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let window = Double(max(dayWindow, 0)) * 86_400
            return try Row.fetchAll(db, sql: """
                SELECT * FROM appointment
                WHERE patient_id = ? AND encounter_id IS NULL AND starts_at BETWEEN ? AND ?
                  AND (? IS NULL OR TRIM(hospital) = ?)
                ORDER BY ABS(starts_at - ?), starts_at
                """, arguments: [patientId.uuidString, date - window, date + window,
                                 hospital?.isEmpty == false ? hospital : nil, hospital, date])
            .map(Self.appointmentRow)
        }
    }

    /// 就诊存在、同成员、未软删——否则 `invalidEncounter`（不区分不存在与他人的，不泄露存在性）。
    private static func assertEncounter(_ encounterId: UUID, belongsTo patientId: UUID, db: Database) throws {
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM encounter WHERE id = ? AND patient_id = ? AND deleted_at IS NULL",
                               arguments: [encounterId.uuidString, patientId.uuidString]) == 1 else { throw StoreError.invalidEncounter }
    }

    private static func appointmentRow(_ row: Row) -> AppointmentRow {
        AppointmentRow(
            id: UUID(uuidString: row["id"] as String) ?? UUID(),
            hospital: (row["hospital"] as String?) ?? "",
            department: (row["department"] as String?) ?? "",
            startsAt: Date(timeIntervalSince1970: row["starts_at"] as Double),
            status: row["status"] as String,
            encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
            purpose: row["purpose"] as String?)
    }
}

public struct AppointmentRow: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var hospital: String
    public var department: String
    public var startsAt: Date
    public var status: String
    /// v27：所挂就诊与预约目的（CHECK 枚举 raw；旧行 nil）。
    public var encounterId: UUID?
    public var purpose: String?
    public init(id: UUID, hospital: String, department: String, startsAt: Date, status: String,
                encounterId: UUID? = nil, purpose: String? = nil) {
        self.id = id; self.hospital = hospital; self.department = department
        self.startsAt = startsAt; self.status = status
        self.encounterId = encounterId; self.purpose = purpose
    }
}
#endif
