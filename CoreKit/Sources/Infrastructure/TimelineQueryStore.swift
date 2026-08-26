#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F11 时间轴 GRDB 联合查询（§5.30）：八类事件投影，游标分页 date DESC / id DESC。
/// 不落物化表——查询即投影，复用各表 idx_*_patient_date 索引；
/// 成员隔离 BR-001 由 SQL 层强制。各表取 limit+1 候选，合并后由 Domain 语义
/// 统一排序 + 游标截取（游标过滤在合并后做，保证跨表分页不重不漏）。
public actor TimelineQueryStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public func entries(for member: UUID, filter: TimelineFilter = .all,
                        cursor: TimelineCursor?, limit: Int = 50) async throws -> TimelinePage {
        var all: [TimelineEntry] = []
        let kinds: Set<TimelineEntryKind> = {
            if case .kinds(let k) = filter { return k }
            return Set(TimelineEntryKind.allCases)
        }()
        let fetchLimit = limit + 1   // 多取一条探测是否有下一页（合并后统一截取）
        try await writer.read { db in

            if kinds.contains(.encounter) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, date, kind, diagnosis_text FROM encounter
                    WHERE patient_id = ? AND deleted_at IS NULL
                    ORDER BY date DESC, id DESC LIMIT ?
                    """, arguments: [member.uuidString, fetchLimit])
                for row in rows {
                    all.append(TimelineEntry(
                        kind: .encounter,
                        date: Date(timeIntervalSince1970: row["date"] as Double),
                        title: "就诊 · \(row["kind"] as String)",
                        summary: row["diagnosis_text"] as String?,
                        refID: UUID(uuidString: row["id"] as String) ?? UUID(),
                        memberId: member))
                }
            }
            if kinds.contains(.medication) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT p.id, p.start_date, m.generic_name, m.spec FROM medication_plan p
                    JOIN medication m ON m.id = p.medication_id
                    WHERE p.patient_id = ?
                    ORDER BY p.start_date DESC, p.id DESC LIMIT ?
                    """, arguments: [member.uuidString, fetchLimit])
                for row in rows {
                    all.append(TimelineEntry(
                        kind: .medication,
                        date: Date(timeIntervalSince1970: row["start_date"] as Double),
                        title: "用药计划 · \(row["generic_name"] as String)",
                        summary: row["spec"] as String?,
                        refID: UUID(uuidString: row["id"] as String) ?? UUID(),
                        memberId: member))
                }
            }
            if kinds.contains(.observation) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, kind, occurred_at, description FROM observation
                    WHERE patient_id = ?
                    ORDER BY occurred_at DESC, id DESC LIMIT ?
                    """, arguments: [member.uuidString, fetchLimit])
                for row in rows {
                    all.append(TimelineEntry(
                        kind: .observation,
                        date: Date(timeIntervalSince1970: row["occurred_at"] as Double),
                        title: "观察 · \(row["kind"] as String)",
                        summary: row["description"] as String?,
                        refID: UUID(uuidString: row["id"] as String) ?? UUID(),
                        memberId: member))
                }
            }
            if kinds.contains(.selfMeasured) || kinds.contains(.lab) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, metric_key, value, unit, origin, measured_at FROM metric_sample
                    WHERE patient_id = ?
                    ORDER BY measured_at DESC, id DESC LIMIT ?
                    """, arguments: [member.uuidString, fetchLimit])
                for row in rows {
                    let origin = row["origin"] as String
                    all.append(TimelineEntry(
                        kind: origin == "hospital" ? .lab : .selfMeasured,
                        date: Date(timeIntervalSince1970: row["measured_at"] as Double),
                        title: "指标 · \(row["metric_key"] as String)",
                        summary: "\(row["value"] as Double) \(row["unit"] as String)",
                        refID: UUID(uuidString: row["id"] as String) ?? UUID(),
                        memberId: member))
                }
            }
            if kinds.contains(.allergy) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, substance, severity, occurred_at FROM allergy_event
                    WHERE patient_id = ?
                    ORDER BY occurred_at DESC, id DESC LIMIT ?
                    """, arguments: [member.uuidString, fetchLimit])
                for row in rows {
                    all.append(TimelineEntry(
                        kind: .allergy,
                        date: Date(timeIntervalSince1970: (row["occurred_at"] as Double?) ?? 0),
                        title: "过敏 · \(row["substance"] as String)",
                        summary: "严重度 \(row["severity"] as String)",
                        refID: UUID(uuidString: row["id"] as String) ?? UUID(),
                        memberId: member))
                }
            }
            if kinds.contains(.vaccination) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, vaccine_name, administered_at FROM immunization
                    WHERE patient_id = ?
                    ORDER BY administered_at DESC, id DESC LIMIT ?
                    """, arguments: [member.uuidString, fetchLimit])
                for row in rows {
                    all.append(TimelineEntry(
                        kind: .vaccination,
                        date: Date(timeIntervalSince1970: (row["administered_at"] as Double?) ?? 0),
                        title: "疫苗 · \(row["vaccine_name"] as String)",
                        summary: nil,
                        refID: UUID(uuidString: row["id"] as String) ?? UUID(),
                        memberId: member))
                }
            }
            if kinds.contains(.voiceNote) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, body, occurred_at FROM voice_note
                    WHERE patient_id = ? AND in_timeline = 1
                    ORDER BY occurred_at DESC, id DESC LIMIT ?
                    """, arguments: [member.uuidString, fetchLimit])
                for row in rows {
                    all.append(TimelineEntry(
                        kind: .voiceNote,
                        date: Date(timeIntervalSince1970: row["occurred_at"] as Double),
                        title: "语音速记",
                        summary: row["body"] as String,
                        refID: UUID(uuidString: row["id"] as String) ?? UUID(),
                        memberId: member))
                }
            }
            if kinds.contains(.healthProblem) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, name, created_at FROM health_problem
                    WHERE patient_id = ? AND archived = 0
                    ORDER BY created_at DESC, id DESC LIMIT ?
                    """, arguments: [member.uuidString, fetchLimit])
                for row in rows {
                    all.append(TimelineEntry(
                        kind: .healthProblem,
                        date: Date(timeIntervalSince1970: row["created_at"] as Double),
                        title: "健康问题 · \(row["name"] as String)",
                        summary: nil,
                        refID: UUID(uuidString: row["id"] as String) ?? UUID(),
                        memberId: member))
                }
            }
        }
        // Domain 语义：统一排序 → 游标过滤 → 分页（跨表不重不漏）
        var merged = TimelineProjectionRules.sort(all)
        if let cursor {
            merged = TimelineProjectionRules.after(merged, cursor: cursor)
        }
        return TimelineProjectionRules.page(merged, limit: limit)
    }
}
#endif
