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
                        cursor: TimelineCursor? = nil, limit: Int = 50) async throws -> TimelinePage {
        let kinds: Set<TimelineEntryKind> = {
            if case .kinds(let k) = filter { return k }
            return Set(TimelineEntryKind.allCases)
        }()
        let fetchLimit = limit + 1   // 多取一条探测是否有下一页
        // 游标谓词下推各分支 SQL（date < ? OR (date = ? AND id < ?)）——
        // 否则单表主导时页长坍缩、深层条目永久不可见（评审 S1-1）
        let cursorDate = cursor?.date.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude
        let cursorId = cursor?.refID.uuidString ?? ""
        let collected: [TimelineEntry] = try await writer.read { db -> [TimelineEntry] in
            // 审查修复（过取）：原实现各表各取 limit+1 行（8 次查询、最坏 8×(limit+1)
            // 行抓取）再合并截断。改为单条 UNION ALL 全局 ORDER BY + LIMIT——
            // 精确取页、一次往返，且每分支带统一列别名（id/d/title/summary/grade/kind）。
            // 同时补 document 分支并携带来源徽章 grade（BR-003 D 级在时间轴可见）。
            var branches: [String] = []
            var args: [DatabaseValueConvertible] = []
            // 每分支占位符序：patient_id + 游标三元组（date/date/id）——逐分支重复
            func branch(kind: String, sql: String) {
                branches.append(sql)
                args.append(contentsOf: [member.uuidString, cursorDate, cursorDate, cursorId])
            }
            if kinds.contains(.encounter) {
                branch(kind: "encounter", sql: """
                    SELECT id AS id, date AS d, '就诊 · ' || kind AS title, diagnosis_text AS summary, 'C' AS grade, 'encounter' AS kind, NULL AS metric_key
                    FROM encounter
                    WHERE patient_id = ? AND deleted_at IS NULL
                      AND (date < ? OR (date = ? AND id < ?))
                    """)
            }
            if kinds.contains(.medication) {
                branch(kind: "medication", sql: """
                    SELECT p.id AS id, p.start_date AS d, '用药计划 · ' || m.generic_name AS title, m.spec AS summary, 'C' AS grade, 'medication' AS kind, NULL AS metric_key
                    FROM medication_plan p JOIN medication m ON m.id = p.medication_id
                    WHERE p.patient_id = ?
                      AND (p.start_date < ? OR (p.start_date = ? AND p.id < ?))
                    """)
            }
            if kinds.contains(.observation) {
                branch(kind: "observation", sql: """
                    SELECT id AS id, occurred_at AS d, '观察 · ' || kind AS title, description AS summary, 'C' AS grade, 'observation' AS kind, NULL AS metric_key
                    FROM observation
                    WHERE patient_id = ?
                      AND (occurred_at < ? OR (occurred_at = ? AND id < ?))
                    """)
            }
            if kinds.contains(.selfMeasured) || kinds.contains(.lab) {
                branch(kind: "metric", sql: """
                    SELECT id AS id, measured_at AS d, '指标 · ' || metric_key AS title,
                           CAST(value AS TEXT) || ' ' || unit AS summary, 'C' AS grade,
                           CASE WHEN origin = 'hospital' THEN 'lab' ELSE 'selfMeasured' END AS kind,
                           metric_key AS metric_key
                    FROM metric_sample
                    WHERE patient_id = ? AND excluded = 0
                      AND (measured_at < ? OR (measured_at = ? AND id < ?))
                    """)
            }
            if kinds.contains(.allergy) {
                branch(kind: "allergy", sql: """
                    SELECT id AS id, occurred_at AS d, '过敏 · ' || substance AS title, '严重度 ' || severity AS summary, 'C' AS grade, 'allergy' AS kind, NULL AS metric_key
                    FROM allergy_event
                    WHERE patient_id = ?
                      AND (occurred_at < ? OR (occurred_at = ? AND id < ?))
                    """)
            }
            if kinds.contains(.vaccination) {
                branch(kind: "vaccination", sql: """
                    SELECT id AS id, administered_at AS d, '疫苗 · ' || vaccine_name AS title, NULL AS summary, 'C' AS grade, 'vaccination' AS kind, NULL AS metric_key
                    FROM immunization
                    WHERE patient_id = ?
                      AND (administered_at < ? OR (administered_at = ? AND id < ?))
                    """)
            }
            if kinds.contains(.voiceNote) {
                branch(kind: "voiceNote", sql: """
                    SELECT id AS id, occurred_at AS d, '语音速记' AS title, body AS summary, 'C' AS grade, 'voiceNote' AS kind, NULL AS metric_key
                    FROM voice_note
                    WHERE patient_id = ? AND in_timeline = 1
                      AND (occurred_at < ? OR (occurred_at = ? AND id < ?))
                    """)
            }
            if kinds.contains(.healthProblem) {
                branch(kind: "healthProblem", sql: """
                    SELECT id AS id, created_at AS d, '健康问题 · ' || name AS title, NULL AS summary, 'C' AS grade, 'healthProblem' AS kind, NULL AS metric_key
                    FROM health_problem
                    WHERE patient_id = ? AND archived = 0
                      AND (created_at < ? OR (created_at = ? AND id < ?))
                    """)
            }
            // 资料（F5 文档）：唯一携带真实来源徽章的分支——机器识别未确认 = 'D'
            if kinds.contains(.document) {
                branch(kind: "document", sql: """
                    SELECT id AS id, created_at AS d, COALESCE(title, '资料') AS title, NULL AS summary, grade AS grade, 'document' AS kind, NULL AS metric_key
                    FROM document_file
                    WHERE patient_id = ? AND status IN ('active','favorite')
                      AND (created_at < ? OR (created_at = ? AND id < ?))
                    """)
            }
            guard !branches.isEmpty else { return [] }
            let sql = branches.joined(separator: "\n UNION ALL\n")
                + "\n ORDER BY d DESC, id DESC LIMIT ?"
            args.append(fetchLimit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                TimelineEntry(
                    kind: TimelineEntryKind(rawValue: row["kind"] as String) ?? .observation,
                    date: Date(timeIntervalSince1970: row["d"] as Double),
                    title: row["title"] as String,
                    summary: row["summary"] as String?,
                    refID: UUID(uuidString: row["id"] as String) ?? UUID(),
                    memberId: member,
                    grade: row["grade"] as String?,
                    metricKey: row["metric_key"] as String?)
            }
        }
        // 游标谓词已下推各分支，合并结果即页内序列——直接分页
        return TimelineProjectionRules.page(collected, limit: limit)
    }

}
#endif
