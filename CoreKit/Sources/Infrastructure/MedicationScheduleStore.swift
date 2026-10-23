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
        public var times: [String]
        public var boundPlanCount: Int
        public init(id: UUID, patientId: UUID, name: String?, times: [String],
                    boundPlanCount: Int) {
            self.id = id; self.patientId = patientId; self.name = name
            self.times = times; self.boundPlanCount = boundPlanCount
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
        case invalidTimes(MedicationScheduleTemplateRules.ValidationError)
        public var errorDescription: String? { "用药计划操作失败: \(self)" }
    }

    @discardableResult
    public func create(patientId: UUID, name: String?, times: [String],
                       now: Date = Date()) async throws -> UUID {
        if let error = MedicationScheduleTemplateRules.validate(times) {
            throw StoreError.invalidTimes(error)
        }
        let normalized = MedicationScheduleTemplateRules.normalize(times)
        let id = UUID()
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO medication_schedule
                  (id, patient_id, name, times_json, created_at, updated_at)
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
                            times: Self.decode(row["times_json"] as String? ?? "[]"),
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
                               times: Self.decode(row["times_json"] as String? ?? "[]"),
                               boundPlanCount: row["bound_count"] as Int? ?? 0)
        }
    }

    /// 全字段更新；行不存在抛 notFound（UPDATE 0 行不得静默成功）。
    public func update(id: UUID, name: String?, times: [String],
                       now: Date = Date()) async throws {
        if let error = MedicationScheduleTemplateRules.validate(times) {
            throw StoreError.invalidTimes(error)
        }
        let normalized = MedicationScheduleTemplateRules.normalize(times)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE medication_schedule
                   SET name = ?, times_json = ?, updated_at = ?
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

    private static func encode(_ times: [String]) -> String {
        guard let data = try? JSONEncoder().encode(times) else { return "[]" }   // try?-ok: [String] 编码不会失败
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func decode(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let times = try? JSONDecoder().decode([String].self, from: data) else { return [] }   // try?-ok: 损坏 times_json 按空模板降级（读侧显示为未配置）
        return MedicationScheduleTemplateRules.normalize(times)
    }
}
#endif
