#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— 须经 macOS CI 验证
import Foundation
import GRDB
import Domain
import Protocols

/// 用药计划模板仓（v42；2026-10-23 业主裁决）：计划 = 一天中的固定服药时段，
/// **与药品无关**；药品与计划的关联是「用药提醒」动作，落在 medication_plan
/// （绑定行，`schedule_id` 指向本表）。
///
/// 删除语义：模板被任何绑定行引用时拒绝硬删（`inUse`）——绑定行承载剂量日志、
/// 库存扣减与通知身份，删模板不得级联抹掉医疗事实（BR-002/BR-004）。用户应先
/// 结束/删除对应用药提醒，再删模板。
public actor MedicationScheduleStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public struct TemplateRow: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var patientId: UUID
        public var name: String?
        /// 条目（时段身份 + 时刻 + 常用提醒范围）；`time` 是唯一排程事实。
        public var entries: [MedicationScheduleEntry]
        public var boundPlanCount: Int
        /// 兼容派生：提醒时刻集合。
        public var times: [String] { MedicationScheduleEntryRules.times(entries) }
        public init(id: UUID, patientId: UUID, name: String?,
                    entries: [MedicationScheduleEntry], boundPlanCount: Int) {
            self.id = id; self.patientId = patientId; self.name = name
            self.entries = entries; self.boundPlanCount = boundPlanCount
        }
    }

    /// 绑定行摘要（模板详情页：「阿托伐他汀 · 20mg · active」）。
    public struct BindingRow: Sendable, Equatable, Identifiable {
        public var id: UUID            // medication_plan.id
        public var medicationName: String
        public var spec: String?
        public var status: String
        public init(id: UUID, medicationName: String, spec: String?, status: String) {
            self.id = id; self.medicationName = medicationName
            self.spec = spec; self.status = status
        }
    }

    public enum StoreError: Error, LocalizedError {
        case notFound(UUID)
        case inUse(UUID, count: Int)
        case invalidEntries(MedicationScheduleEntryRules.ValidationError)
        public var errorDescription: String? { "用药计划操作失败: \(self)" }
    }

    @discardableResult
    public func create(patientId: UUID, name: String?, entries: [MedicationScheduleEntry],
                       now: Date = Date()) async throws -> UUID {
        if let error = MedicationScheduleEntryRules.validate(entries) {
            throw StoreError.invalidEntries(error)
        }
        let normalized = MedicationScheduleEntryRules.normalize(entries)
        let id = UUID()
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO medication_schedule
                  (id, patient_id, name, entries_json, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString,
                                 (trimmedName?.isEmpty == false) ? trimmedName : nil,
                                 Self.encode(normalized),
                                 now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
        return id
    }

    public func list(patientId: UUID) async throws -> [TemplateRow] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.*, (SELECT COUNT(*) FROM medication_plan p WHERE p.schedule_id = s.id)
                       AS bound_count
                  FROM medication_schedule s
                 WHERE s.patient_id = ?
                 ORDER BY s.created_at DESC, s.rowid DESC
                """, arguments: [patientId.uuidString])
            return rows.map { row in
                TemplateRow(id: UUID(uuidString: row["id"]) ?? UUID(),
                            patientId: patientId,
                            name: row["name"] as String?,
                            entries: Self.decode(row["entries_json"] as String? ?? "[]"),
                            boundPlanCount: row["bound_count"] as Int? ?? 0)
            }
        }
    }

    /// 单条模板读取（编辑路由按 id 回填）。
    public func template(id: UUID) async throws -> TemplateRow {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT s.*, (SELECT COUNT(*) FROM medication_plan p WHERE p.schedule_id = s.id)
                       AS bound_count
                  FROM medication_schedule s WHERE s.id = ?
                """, arguments: [id.uuidString]) else {
                throw StoreError.notFound(id)
            }
            return TemplateRow(id: id,
                               patientId: UUID(uuidString: row["patient_id"]) ?? UUID(),
                               name: row["name"] as String?,
                               entries: Self.decode(row["entries_json"] as String? ?? "[]"),
                               boundPlanCount: row["bound_count"] as Int? ?? 0)
        }
    }

    /// 全字段更新；行不存在抛 notFound（UPDATE 0 行不得静默成功）。
    public func update(id: UUID, name: String?, entries: [MedicationScheduleEntry],
                       now: Date = Date()) async throws {
        if let error = MedicationScheduleEntryRules.validate(entries) {
            throw StoreError.invalidEntries(error)
        }
        let normalized = MedicationScheduleEntryRules.normalize(entries)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE medication_schedule
                   SET name = ?, entries_json = ?, updated_at = ?
                 WHERE id = ?
                """, arguments: [(trimmedName?.isEmpty == false) ? trimmedName : nil,
                                 Self.encode(normalized), now.timeIntervalSince1970,
                                 id.uuidString])
            guard db.changesCount > 0 else { throw StoreError.notFound(id) }
        }
    }

    /// 模板被绑定行引用时拒绝删除（见类型注释：不级联医疗事实）。
    public func delete(id: UUID) async throws {
        try await writer.write { db in
            guard try Row.fetchOne(db, sql: "SELECT id FROM medication_schedule WHERE id = ?",
                                   arguments: [id.uuidString]) != nil else {
                throw StoreError.notFound(id)
            }
            let bound = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM medication_plan WHERE schedule_id = ?",
                arguments: [id.uuidString]) ?? 0
            guard bound == 0 else { throw StoreError.inUse(id, count: bound) }
            try db.execute(sql: "DELETE FROM medication_schedule WHERE id = ?",
                           arguments: [id.uuidString])
            guard db.changesCount > 0 else { throw StoreError.notFound(id) }
        }
    }

    /// 模板下的药品绑定（用药提醒）列表，按创建时间倒序。
    public func bindings(scheduleId: UUID) async throws -> [BindingRow] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id, m.generic_name, m.spec, p.status
                  FROM medication_plan p
                  JOIN medication m ON m.id = p.medication_id
                 WHERE p.schedule_id = ?
                 ORDER BY p.created_at DESC
                """, arguments: [scheduleId.uuidString])
            return rows.map { row in
                BindingRow(id: UUID(uuidString: row["id"]) ?? UUID(),
                           medicationName: row["generic_name"] as String? ?? "",
                           spec: row["spec"] as String?,
                           status: row["status"] as String? ?? "active")
            }
        }
    }

    private static func encode(_ entries: [MedicationScheduleEntry]) -> String {
        guard let data = try? JSONEncoder().encode(entries) else { return "[]" }   // try?-ok: 条目数组编码不会失败
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// 宽容解码：条目数组 → 逐条；旧版 `[String]` → 按时段默认时刻认领；损坏 → []。
    private static func decode(_ json: String) -> [MedicationScheduleEntry] {
        guard let data = json.data(using: .utf8) else { return [] }
        if let entries = try? JSONDecoder().decode([MedicationScheduleEntry].self, from: data) {   // try?-ok: 格式探测；失败走旧格式
            return MedicationScheduleEntryRules.normalize(entries)
        }
        if let times = try? JSONDecoder().decode([String].self, from: data) {   // try?-ok: 旧 times_json 兼容读取
            return MedicationScheduleEntryRules.normalize(
                MedicationScheduleEntryRules.entries(fromLegacyTimes: times))
        }
        return []
    }
}
#endif
