#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain

/// v27（子项目 J · FR8.10 / FR10.2 / round1 §E.1）：通用提醒表 `reminder` 的**首个写入方**——带来源回指
/// （`source_table` / `source_id` 多态引用：encounter / appointment / health_exam 白名单，无 FK，由本 store 校验）。
/// 系统通知排程仍由 `ReminderScheduling` 承担（本 store 只落库，不排通知——App 层拿返回 id 自行排程，与预约四级提醒同纪律）。
///
/// 纪律：成员隔离（每条读写带 `patient_id`；来源实体须同成员，否则 `invalidSource` 零写入）；表名只来自
/// `ReminderSource.allowedTables` 常量方可拼入 SQL；`kind` / `status` 走 DDL CHECK 同枚举，在包内先拒。
public actor ReminderLinkStore {
    public enum Error: Swift.Error, Equatable {
        /// 来源表不在白名单 / 来源实体不存在或属于其他成员（不区分、不泄露存在性）。
        case invalidSource
        /// `kind` 不在 CHECK 枚举内。
        case invalidKind
        /// 提醒不存在或不属于该成员（零行更新，§7 不得静默 return）。
        case notFound
    }

    /// `reminder.kind` CHECK 枚举（SchemaV2 同拼写）。
    public static let kinds: Set<String> = ["followUp", "examPrep", "selfTest", "medLog", "appointment", "any"]

    public struct ReminderRow: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let patientId: UUID
        public let kind: String
        public let title: String
        public let atDate: Date
        public let repeats: String?
        public let status: String
        /// 来源回指（白名单外 / 缺失 → nil）。
        public let source: ReminderSource?
        public init(id: UUID, patientId: UUID, kind: String, title: String, atDate: Date, repeats: String?, status: String, source: ReminderSource?) {
            self.id = id; self.patientId = patientId; self.kind = kind; self.title = title
            self.atDate = atDate; self.repeats = repeats; self.status = status; self.source = source
        }
    }

    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// 新建提醒（`status = 'active'`, `source = 'manual'`）；`source` 非 nil 时校验白名单 + 同成员实体存在。返回提醒 id。
    @discardableResult
    public func create(id: UUID = UUID(), patientId: UUID, kind: String, title: String, at: Date,
                       source: ReminderSource?, repeats: String? = nil, now: Date = Date()) async throws -> UUID {
        guard Self.kinds.contains(kind) else { throw Error.invalidKind }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, at.timeIntervalSince1970.isFinite else { throw Error.invalidSource }
        try await writer.write { db in
            if let source { try Self.assertSource(source, belongsTo: patientId, db: db) }
            try db.execute(sql: """
                INSERT INTO reminder (id, patient_id, kind, title, at_date, repeats, status, source, channel_pref, source_table, source_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 'active', 'manual', NULL, ?, ?, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString, kind, trimmed, at.timeIntervalSince1970, repeats,
                                 source?.table, source?.id.uuidString, now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
        return id
    }

    /// 来源回指设置 / 清除（App 层「挂到就诊 / 体检」入口）：白名单 + 同成员校验；零行 → `notFound`。
    public func setSource(reminderId: UUID, patientId: UUID, source: ReminderSource?, now: Date = Date()) async throws {
        try await writer.write { db in
            if let source { try Self.assertSource(source, belongsTo: patientId, db: db) }
            try db.execute(sql: "UPDATE reminder SET source_table = ?, source_id = ?, updated_at = ? WHERE id = ? AND patient_id = ?",
                           arguments: [source?.table, source?.id.uuidString, now.timeIntervalSince1970, reminderId.uuidString, patientId.uuidString])
            guard db.changesCount == 1 else { throw Error.notFound }
        }
    }

    /// 状态流转（active → done / cancelled）；零行 → `notFound`。
    public func setStatus(reminderId: UUID, patientId: UUID, status: String, now: Date = Date()) async throws {
        guard ["active", "done", "cancelled"].contains(status) else { throw Error.invalidKind }
        try await writer.write { db in
            try db.execute(sql: "UPDATE reminder SET status = ?, updated_at = ? WHERE id = ? AND patient_id = ?",
                           arguments: [status, now.timeIntervalSince1970, reminderId.uuidString, patientId.uuidString])
            guard db.changesCount == 1 else { throw Error.notFound }
        }
    }

    /// 某来源实体下的活跃提醒（就诊页「随访提醒」分段 / 体检详情）；白名单外来源 → 空。
    public func linked(source: ReminderSource, patientId: UUID, includeInactive: Bool = false) async throws -> [ReminderRow] {
        guard source.isAllowed else { return [] }
        return try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM reminder WHERE patient_id = ? AND source_table = ? AND source_id = ?
                  AND (? = 1 OR status = 'active')
                ORDER BY at_date
                """, arguments: [patientId.uuidString, source.table, source.id.uuidString, includeInactive ? 1 : 0])
            .compactMap(Self.reminderRow)
        }
    }

    /// 成员的全部提醒（按时间）；`activeOnly` 缺省只取 active。
    public func list(patientId: UUID, activeOnly: Bool = true, limit: Int = 200) async throws -> [ReminderRow] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM reminder WHERE patient_id = ? AND (? = 0 OR status = 'active') ORDER BY at_date LIMIT ?
                """, arguments: [patientId.uuidString, activeOnly ? 1 : 0, limit])
            .compactMap(Self.reminderRow)
        }
    }

    /// 白名单表 + 同成员实体存在（就诊还须未软删）；表名只取白名单常量。
    private static func assertSource(_ source: ReminderSource, belongsTo patientId: UUID, db: Database) throws {
        guard ReminderSource.allowedTables.contains(source.table) else { throw Error.invalidSource }
        let extra = source.table == "encounter" ? " AND deleted_at IS NULL" : ""
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(source.table) WHERE id = ? AND patient_id = ?\(extra)",
                               arguments: [source.id.uuidString, patientId.uuidString]) == 1 else { throw Error.invalidSource }
    }

    private static func reminderRow(_ row: Row) -> ReminderRow? {
        guard let id = UUID(uuidString: row["id"] as String), let patient = UUID(uuidString: row["patient_id"] as String) else { return nil }
        let source: ReminderSource? = {
            guard let table = row["source_table"] as String?, let raw = row["source_id"] as String?, let sourceId = UUID(uuidString: raw) else { return nil }
            return ReminderSource(validating: table, id: sourceId)
        }()
        return ReminderRow(id: id, patientId: patient, kind: row["kind"] as String, title: row["title"] as String,
                           atDate: Date(timeIntervalSince1970: row["at_date"] as Double), repeats: row["repeats"] as String?,
                           status: row["status"] as String, source: source)
    }
}
#endif
