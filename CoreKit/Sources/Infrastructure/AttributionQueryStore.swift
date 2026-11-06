#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain

/// 孤儿归属只读查询（2026-11-06 三轮/红队结论）：从现有事实表收集
/// `encounter_id IS NULL` 的已确认卡与就诊候选，交给纯 Domain `AttributionPlanner`
/// 出候选。**零写入**；真正的归属仍由 `OCRCardStore.associate` / `EncounterStore.linkDocument`
/// 在用户确认后执行。不建关系表、不建图。
///
/// 只收集有 hospital 的临床事实：处方 / 检验表头 / 检查报告 / 手术 / 治疗。
/// 诊断、票据、免疫等无医院字段或已有专门例外，不进入自动归属候选；不做猜测。
public actor AttributionQueryStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public func suggestions(patientId: UUID, now: Date = Date(),
                            calendar: Calendar = .current) async throws -> [AttributionSuggestion] {
        try await writer.read { db in
            let orphans = try Self.orphans(db, patientId: patientId)
            let encounters = try Self.encounters(db, patientId: patientId)
            return AttributionPlanner.plan(patientId: patientId, orphans: orphans,
                                           encounters: encounters, now: now, calendar: calendar)
        }
    }

    private struct OrphanSource {
        let kind: String
        let documentTypeKey: String
        let table: String
        let dateExpression: String
        let hospitalExpression: String
        let departmentExpression: String
        let doctorExpression: String
    }

    /// 白名单 SQL 片段（表名/列名固定；不拼接用户输入）。
    private static let sources: [OrphanSource] = [
        OrphanSource(kind: "prescription", documentTypeKey: "prescription", table: "prescription",
                     dateExpression: "t.prescribed_at", hospitalExpression: "t.hospital",
                     departmentExpression: "t.department", doctorExpression: "t.doctor"),
        OrphanSource(kind: "metric_sample", documentTypeKey: "lab_report", table: "lab_report",
                     dateExpression: "COALESCE(t.collected_at, t.reported_at)",
                     hospitalExpression: "t.hospital", departmentExpression: "t.department",
                     doctorExpression: "COALESCE(t.send_doctor, t.review_doctor)"),
        OrphanSource(kind: "exam_report", documentTypeKey: "exam_report", table: "exam_report",
                     dateExpression: "COALESCE(t.exam_at, t.reported_at)",
                     hospitalExpression: "t.hospital", departmentExpression: "t.department",
                     doctorExpression: "t.apply_doctor"),
        OrphanSource(kind: "surgery", documentTypeKey: "surgery_record", table: "surgery",
                     dateExpression: "t.surgery_at", hospitalExpression: "t.hospital",
                     departmentExpression: "t.department", doctorExpression: "t.surgeon"),
        OrphanSource(kind: "treatment_record", documentTypeKey: "treatment_record", table: "treatment_record",
                     dateExpression: "t.treated_at", hospitalExpression: "t.hospital",
                     departmentExpression: "t.department", doctorExpression: "t.doctor"),
    ]

    private static func orphans(_ db: Database, patientId: UUID) throws -> [OrphanCard] {
        var out: [OrphanCard] = []
        for source in sources {
            let sql = """
                SELECT t.id AS id, t.patient_id AS patient_id,
                       \(source.dateExpression) AS date,
                       \(source.hospitalExpression) AS hospital,
                       \(source.departmentExpression) AS department,
                       \(source.doctorExpression) AS doctor,
                       (SELECT d.sha256 FROM document_file d WHERE d.id = t.document_file_id) AS document_sha
                FROM \(source.table) t
                WHERE t.patient_id = ? AND t.encounter_id IS NULL AND t.confirmed = 1
                  AND \(source.hospitalExpression) IS NOT NULL
                  AND TRIM(\(source.hospitalExpression)) <> ''
                ORDER BY \(source.dateExpression) DESC
                """
            for row in try Row.fetchAll(db, sql: sql, arguments: [patientId.uuidString]) {
                guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                      let pid = (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                      pid == patientId else { continue }
                out.append(OrphanCard(
                    patientId: pid, kind: source.kind, documentTypeKey: source.documentTypeKey,
                    entityId: id, documentSha256: row["document_sha"] as String?,
                    pageIndex: nil, rowAnchor: nil,
                    date: (row["date"] as Double?).map { Date(timeIntervalSince1970: $0) },
                    hospital: row["hospital"] as String?, department: row["department"] as String?,
                    doctor: row["doctor"] as String?, currentEncounterId: nil))
            }
        }
        return out
    }

    private static func encounters(_ db: Database, patientId: UUID) throws -> [EncounterCandidate] {
        let sql = """
            SELECT e.id AS id, e.patient_id AS patient_id, e.date AS date, e.kind AS kind,
                   e.hospital AS hospital, e.department AS department, e.doctor AS doctor,
                   h.admit_at AS admit_at, h.discharge_at AS discharge_at
            FROM encounter e
            LEFT JOIN hospitalization h ON h.encounter_id = e.id
            WHERE e.patient_id = ? AND e.deleted_at IS NULL
            ORDER BY e.date DESC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [patientId.uuidString]).compactMap { row in
            guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                  let pid = (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                  pid == patientId,
                  let date = row["date"] as Double? else { return nil }
            return EncounterCandidate(
                id: id, patientId: pid, date: Date(timeIntervalSince1970: date),
                kind: (row["kind"] as String?) ?? "",
                hospital: row["hospital"] as String?, department: row["department"] as String?,
                doctor: row["doctor"] as String?,
                stayStart: (row["admit_at"] as Double?).map { Date(timeIntervalSince1970: $0) },
                stayEnd: (row["discharge_at"] as Double?).map { Date(timeIntervalSince1970: $0) })
        }
    }
}
#endif
