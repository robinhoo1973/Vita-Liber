// 平台守卫镜像 Package.swift（ERR#8 纪律）
#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

/// F15 紧急信息卡仓储（actor）。
///
/// 三数据源 + 联系人：
/// - 过敏 = allergy_event（F23 一等事件；`consulted_doctor=0` 且无医生确认
///   的条目仍可入卡吗？不——FR15.1 数据源是 F3 P1 字段 + F23 事件**且用户逐项确认**。
///   确认语义 = 用户显式选择（`emergency_card_selection`），不由来源推断）
/// - 用药 = 已确认且当前有效（`medication_plan.status='active'`）的计划
/// - 健康问题 = `health_problem`（未归档）
/// - 联系人 = `contact.is_emergency=1`
///
/// **FR15.1 的「逐项选择」是可执行语义，不是文案**：只有出现在
/// `emergency_card_selection` 里的条目才入卡。聚合查询直接 JOIN 数据表，
/// 就是把「数据存在」当成「用户同意入卡」——静默行为的温床。
public actor EmergencyCardStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    // MARK: - 选择（FR15.1 逐项选择）

    public func select(patientId: UUID, itemId: UUID, kind: String) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO emergency_card_selection (patient_id, item_id, item_kind, selected_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(patient_id, item_id) DO UPDATE SET selected_at = excluded.selected_at
                """, arguments: [patientId.uuidString, itemId.uuidString, kind,
                                 Date().timeIntervalSince1970])
        }
    }

    public func deselect(patientId: UUID, itemId: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                DELETE FROM emergency_card_selection WHERE patient_id = ? AND item_id = ?
                """, arguments: [patientId.uuidString, itemId.uuidString])
        }
    }

    // MARK: - 聚合（只聚合已选条目；BR-003 未确认不入卡）

    /// 全部候选（供选择页展示）——**不含**选择状态，选择页自行标出。
    public func candidates(patientId: UUID) async throws -> EmergencyCard {
        try await writer.read { db in
            var card = EmergencyCard(patientId: patientId)
            card.allergies = try Self.allergyCandidates(db, patientId: patientId)
            card.medications = try Self.medicationCandidates(db, patientId: patientId)
            card.healthProblems = try Self.healthProblemCandidates(db, patientId: patientId)
            card.contacts = try Self.contactCandidates(db, patientId: patientId)
            return card
        }
    }

    /// 已选集合（急救卡展示内容）
    public func selected(patientId: UUID) async throws -> EmergencyCard {
        let all = try await candidates(patientId: patientId)
        let chosen = try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT item_id FROM emergency_card_selection WHERE patient_id = ?
                """, arguments: [patientId.uuidString])
        }
        let ids = Set(chosen.compactMap { UUID(uuidString: $0) })
        let filter: ([EmergencyCardItem]) -> [EmergencyCardItem] = { items in
            items.filter { ids.contains($0.id) && $0.confirmed }
        }
        return EmergencyCard(patientId: patientId,
                             allergies: filter(all.allergies),
                             medications: filter(all.medications),
                             healthProblems: filter(all.healthProblems),
                             contacts: filter(all.contacts))
    }

    // MARK: - 候选查询（confirmed 语义逐源定义）

    private static func allergyCandidates(_ db: Database, patientId: UUID) throws -> [EmergencyCardItem] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, substance, reaction_tags, severity FROM allergy_event
            WHERE patient_id = ? ORDER BY occurred_at DESC
            """, arguments: [patientId.uuidString])
        return rows.map { row in
            EmergencyCardItem(
                id: UUID(uuidString: row["id"] as String) ?? UUID(),
                kind: "allergy", title: row["substance"] as String,
                detail: "反应：\(row["reaction_tags"] as String) · 严重度 \(row["severity"] as String)",
                // 过敏事件是用户主动记录的一等事件（ADR-018），记录即确认
                confirmed: true)
        }
    }

    private static func medicationCandidates(_ db: Database, patientId: UUID) throws -> [EmergencyCardItem] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT p.id, m.generic_name, m.spec, m.unit_kind
            FROM medication_plan p
            JOIN medication m ON m.id = p.medication_id
            WHERE p.patient_id = ? AND p.status = 'active'
            """, arguments: [patientId.uuidString])
        return rows.map { row in
            EmergencyCardItem(
                id: UUID(uuidString: row["id"] as String) ?? UUID(),
                kind: "medication", title: row["generic_name"] as String,
                detail: (row["spec"] as String?) ?? "",
                confirmed: true)   // active 计划即「已确认且当前有效」（FR15.1）
        }
    }

    private static func healthProblemCandidates(_ db: Database, patientId: UUID) throws -> [EmergencyCardItem] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, name, kind FROM health_problem
            WHERE patient_id = ? AND archived = 0
            """, arguments: [patientId.uuidString])
        return rows.map { row in
            EmergencyCardItem(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                              kind: "healthProblem", title: row["name"] as String,
                              detail: (row["kind"] as String?) ?? "",
                              confirmed: true)   // 用户手录的健康问题即确认
        }
    }

    private static func contactCandidates(_ db: Database, patientId: UUID) throws -> [EmergencyCardItem] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, name, relation, phone FROM contact
            WHERE patient_id = ? AND is_emergency = 1
            """, arguments: [patientId.uuidString])
        return rows.map { row in
            EmergencyCardItem(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                              kind: "contact", title: row["name"] as String,
                              detail: "\(row["relation"] as String) · \(row["phone"] as String)",
                              confirmed: true)
        }
    }

    /// 血型（F3 P1 字段，随急救卡直接带出——用户档案字段即确认态）
    public func bloodType(patientId: UUID) async throws -> String? {
        try await writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT blood_type FROM patient_profile WHERE id = ?
                """, arguments: [patientId.uuidString])
        }
    }
}
#endif
