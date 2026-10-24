#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— 须经 macOS CI 验证
import Foundation
import GRDB
import Domain
import Protocols

/// 用药时段仓（v45；2026-10-24 业主：用药计划改名用药时段，页面扁平化为单页）。
///
/// 每成员一个默认时段文档（`medication_schedule.is_default = 1`，部分唯一索引）。
/// 旧模板保留、不删、不合并、不重指——它们是迁移与回滚资产，调度从不读它们。
///
/// 语义：
/// - `entries_json` 的 `time` 是唯一排程事实；范围是展示元数据。
/// - 保存默认时段时，**仅**更新「带时段连接键」的用药提醒（`slot_keys_json`）：
///   按键解析新时刻、重写 `schedule_json`、删除未来未确认的 `planned` 剂量行；
///   历史与已确认剂量一律不动（BR-004）。无键的旧提醒保持独立时刻。
public actor MedicationScheduleStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public struct ScheduleRow: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var patientId: UUID
        public var entries: [MedicationScheduleEntry]
        public var boundPlanCount: Int
        public var times: [String] { MedicationScheduleEntryRules.times(entries) }
        public init(id: UUID, patientId: UUID,
                    entries: [MedicationScheduleEntry], boundPlanCount: Int) {
            self.id = id; self.patientId = patientId
            self.entries = entries; self.boundPlanCount = boundPlanCount
        }
    }

    /// 保存结果：`followedPlanIds` 为时刻被改写的提醒（App 侧据此对账通知）。
    public struct UpdateResult: Sendable, Equatable {
        public var scheduleId: UUID
        public var followedPlanIds: [UUID]
        public var legacyPlanCount: Int
        public init(scheduleId: UUID, followedPlanIds: [UUID], legacyPlanCount: Int) {
            self.scheduleId = scheduleId
            self.followedPlanIds = followedPlanIds
            self.legacyPlanCount = legacyPlanCount
        }
    }

    public enum StoreError: Error, LocalizedError {
        case notFound(UUID)
        case invalidEntries(MedicationScheduleEntryRules.ValidationError)
        public var errorDescription: String? { "用药时段操作失败: \(self)" }
    }

    /// 默认时段（不存在返回 nil；读取不写入）。
    public func defaultSchedule(patientId: UUID) async throws -> ScheduleRow? {
        try await writer.read { db in
            try Self.row(db, patientId: patientId)
        }
    }

    /// 确保默认时段存在：有默认直接用；否则采纳一个旧模板（被引用最多→条目最多→
    /// 最早创建）；一个都没有则用 8 个标准时段懒创建。同一写事务 + 唯一索引兜底。
    @discardableResult
    public func ensureDefaultSchedule(patientId: UUID,
                                      now: Date = Date()) async throws -> ScheduleRow {
        try await writer.write { db in
            if let existing = try Self.row(db, patientId: patientId) { return existing }
            if let adopted = try Self.adoptExisting(db, patientId: patientId) { return adopted }
            let entries = DoseTimeSlot.allCases.map {
                MedicationScheduleEntry(slot: $0, time: $0.defaultTime)
            }
            let id = UUID()
            try db.execute(sql: """
                INSERT OR IGNORE INTO medication_schedule
                  (id, patient_id, name, entries_json, is_default, created_at, updated_at)
                VALUES (?, ?, NULL, ?, 1, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString,
                                 MedicationScheduleEntryCodec.encode(entries),
                                 now.timeIntervalSince1970, now.timeIntervalSince1970])
            guard let row = try Self.row(db, patientId: patientId) else {
                throw StoreError.notFound(id)
            }
            return row
        }
    }

    /// 保存默认时段，并把「跟随时段」的提醒改写到新时刻。
    /// 只改未来尚未确认的 `planned` 剂量行；历史/已确认行不动。
    @discardableResult
    public func updateDefaultEntries(patientId: UUID,
                                     entries: [MedicationScheduleEntry],
                                     propagate: Bool = true,
                                     now: Date = Date()) async throws -> UpdateResult {
        if let error = MedicationScheduleEntryRules.validate(entries) {
            throw StoreError.invalidEntries(error)
        }
        let normalized = MedicationScheduleEntryRules.normalize(entries)
        return try await writer.write { db in
            guard let row = try Self.row(db, patientId: patientId) else {
                throw StoreError.notFound(patientId)
            }
            let scheduleId = row.id
            try db.execute(sql: """
                UPDATE medication_schedule
                   SET entries_json = ?, updated_at = ?
                 WHERE id = ?
                """, arguments: [MedicationScheduleEntryCodec.encode(normalized),
                                 now.timeIntervalSince1970, scheduleId.uuidString])

            // 只传播给仍在进行的提醒：paused/ended 的计划保留原时刻，
            // 不得被改写或删除未来剂量行（审查修正）。
            let plans: [Row] = propagate ? try Row.fetchAll(db, sql: """
                SELECT id, slot_keys_json FROM medication_plan
                 WHERE patient_id = ? AND schedule_id = ? AND status = 'active'
                   AND slot_keys_json IS NOT NULL
                """, arguments: [patientId.uuidString, scheduleId.uuidString]) : []
            var followed: [UUID] = []
            var legacy = 0
            for plan in plans {
                guard let keysJSON = plan["slot_keys_json"] as String?,
                      let data = keysJSON.data(using: .utf8),
                      let keys = try? JSONDecoder().decode([String].self, from: data) else {   // try?-ok: 无键/损坏 = 独立时刻，不猜
                    legacy += 1
                    continue
                }
                let selected = keys.compactMap {
                    MedicationScheduleSlotKey.entry(for: $0, in: normalized)
                }
                let times = MedicationScheduleEntryRules.times(selected)
                // 键全部失效（时段被删）时不改提醒：保留原时刻，界面标记「时段已删除」。
                guard !times.isEmpty else { legacy += 1; continue }
                guard let planId = UUID(uuidString: plan["id"] as String? ?? "") else { continue }
                let scheduleJSON = (try? JSONEncoder().encode(MedicationSchedule.fixed(times: times)))   // try?-ok: 枚举编码不会失败
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                try db.execute(sql: """
                    UPDATE medication_plan
                       SET schedule_json = ?, updated_at = ?
                     WHERE id = ? AND patient_id = ?
                    """, arguments: [scheduleJSON, now.timeIntervalSince1970,
                                     planId.uuidString, patientId.uuidString])
                // 只清理未来未确认的计划行；已送达/已确认/历史行一律保留。
                // 未来、尚未被用户确认的待办剂量行（planned 未投递 / sent 已排通知）
                // 一并清掉，避免旧时刻继续响铃；已交付或已确认的行保留。
                try db.execute(sql: """
                    DELETE FROM medication_dose_log
                     WHERE plan_id = ? AND delivery_state IN ('planned','sent')
                       AND user_action IS NULL AND scheduled_for > ?
                    """, arguments: [planId.uuidString, now.timeIntervalSince1970])
                followed.append(planId)
            }
            return UpdateResult(scheduleId: scheduleId, followedPlanIds: followed,
                                legacyPlanCount: legacy)
        }
    }

    // MARK: - 私有

    private static func row(_ db: Database, patientId: UUID) throws -> ScheduleRow? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT s.*, (SELECT COUNT(*) FROM medication_plan p
                          WHERE p.schedule_id = s.id AND p.status = 'active'
                            AND p.slot_keys_json IS NOT NULL) AS bound_count
              FROM medication_schedule s
             WHERE s.patient_id = ? AND s.is_default = 1
             LIMIT 1
            """, arguments: [patientId.uuidString]) else { return nil }
        return ScheduleRow(id: UUID(uuidString: row["id"] as String? ?? "") ?? UUID(),
                           patientId: patientId,
                           entries: MedicationScheduleEntryCodec.decode(
                               row["entries_json"] as String? ?? "[]"),
                           boundPlanCount: row["bound_count"] as Int? ?? 0)
    }

    private static func adoptExisting(_ db: Database, patientId: UUID) throws -> ScheduleRow? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.*, (SELECT COUNT(*) FROM medication_plan p
                          WHERE p.schedule_id = s.id AND p.status = 'active'
                            AND p.slot_keys_json IS NOT NULL) AS bound_count
              FROM medication_schedule s
             WHERE s.patient_id = ?
             ORDER BY s.created_at ASC, s.rowid ASC
            """, arguments: [patientId.uuidString])
        guard !rows.isEmpty else { return nil }
        let winner = rows.max { a, b in
            let ab = a["bound_count"] as Int? ?? 0
            let bb = b["bound_count"] as Int? ?? 0
            if ab != bb { return ab < bb }
            let ae = MedicationScheduleEntryCodec.decode(a["entries_json"] as String? ?? "[]").count
            let be = MedicationScheduleEntryCodec.decode(b["entries_json"] as String? ?? "[]").count
            if ae != be { return ae < be }
            return (a["created_at"] as Double? ?? 0) > (b["created_at"] as Double? ?? 0)
        }
        guard let winner, let id = winner["id"] as String? else { return nil }
        try db.execute(sql: "UPDATE medication_schedule SET is_default = 1 WHERE id = ?",
                       arguments: [id])
        return try row(db, patientId: patientId)
    }
}
#endif
