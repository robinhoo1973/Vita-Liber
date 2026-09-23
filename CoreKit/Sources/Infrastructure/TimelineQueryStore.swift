#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain
import Protocols

/// F11 时间轴 GRDB 联合查询（§5.30）：八类事件投影，游标分页 date DESC / id DESC。
/// 不落物化表——查询即投影，复用各表 idx_*_patient_date 索引；
/// 成员隔离 BR-001 由 SQL 层强制。单条 UNION ALL 全局排序 + LIMIT 精确取页，
/// 游标谓词下推各分支（date < ? OR (date = ? AND id < ?)），保证跨表分页不重不漏。
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
            // L10n 单出口（V3.94 修复）：title 只回原列值，类别前缀（「就诊 · 」等）
            // 由视图层经 L10n.timelineKindName 组装——此前 SQL 内硬编码简体前缀，
            // zh-Hant 用户看到简体残留。
            var branches: [String] = []
            var args: [DatabaseValueConvertible] = []
            // 每分支占位符序：patient_id + 游标三元组（date/date/id）——逐分支重复
            func branch(sql: String) {
                branches.append(sql)
                args.append(contentsOf: [member.uuidString, cursorDate, cursorDate, cursorId] as [DatabaseValueConvertible])
            }
            if kinds.contains(.encounter) {
                branch(sql: """
                    SELECT id AS id, date AS d, kind AS title, diagnosis_text AS summary, 'C' AS grade, 'encounter' AS kind, NULL AS metric_key
                    FROM encounter
                    WHERE patient_id = ? AND deleted_at IS NULL
                      AND (date < ? OR (date = ? AND id < ?))
                    """)
            }
            if kinds.contains(.medication) {
                branch(sql: """
                    SELECT p.id AS id, p.start_date AS d, m.generic_name AS title, m.spec AS summary, 'C' AS grade, 'medication' AS kind, NULL AS metric_key
                    FROM medication_plan p JOIN medication m ON m.id = p.medication_id
                    WHERE p.patient_id = ?
                      AND (p.start_date < ? OR (p.start_date = ? AND p.id < ?))
                    """)
            }
            if kinds.contains(.observation) {
                branch(sql: """
                    SELECT id AS id, occurred_at AS d, kind AS title, description AS summary, 'C' AS grade, 'observation' AS kind, NULL AS metric_key
                    FROM observation
                    WHERE patient_id = ?
                      AND (occurred_at < ? OR (occurred_at = ? AND id < ?))
                    """)
            }
            if kinds.contains(.selfMeasured) || kinds.contains(.lab) || kinds.contains(.healthData) {
                branch(sql: """
                    SELECT id AS id, measured_at AS d, metric_key AS title,
                           CAST(value AS TEXT) || ' ' || unit AS summary, 'C' AS grade,
                           CASE WHEN origin = 'hospital' THEN 'lab'
                                WHEN origin = 'device' THEN 'healthData'
                                ELSE 'selfMeasured' END AS kind,
                           metric_key AS metric_key
                    FROM metric_sample
                    WHERE patient_id = ? AND excluded = 0
                      AND (measured_at < ? OR (measured_at = ? AND id < ?))
                    """)
            }
            if kinds.contains(.allergy) {
                branch(sql: """
                    SELECT id AS id, occurred_at AS d, substance AS title, severity AS summary, 'C' AS grade, 'allergy' AS kind, NULL AS metric_key
                    FROM allergy_event
                    WHERE patient_id = ?
                      AND (occurred_at < ? OR (occurred_at = ? AND id < ?))
                    """)
            }
            if kinds.contains(.vaccination) {
                branch(sql: """
                    SELECT id AS id, administered_at AS d, vaccine_name AS title, NULL AS summary, 'C' AS grade, 'vaccination' AS kind, NULL AS metric_key
                    FROM immunization
                    WHERE patient_id = ? AND confirmed = 1
                      AND (administered_at < ? OR (administered_at = ? AND id < ?))
                    """)
            }
            if kinds.contains(.voiceNote) {
                branch(sql: """
                    SELECT id AS id, occurred_at AS d, '' AS title, body AS summary, 'C' AS grade, 'voiceNote' AS kind, NULL AS metric_key
                    FROM voice_note
                    WHERE patient_id = ? AND in_timeline = 1
                      AND (occurred_at < ? OR (occurred_at = ? AND id < ?))
                    """)
            }
            if kinds.contains(.healthProblem) {
                branch(sql: """
                    SELECT id AS id, created_at AS d, name AS title, NULL AS summary, 'C' AS grade, 'healthProblem' AS kind, NULL AS metric_key
                    FROM health_problem
                    WHERE patient_id = ? AND archived = 0
                      AND (created_at < ? OR (created_at = ? AND id < ?))
                    """)
            }
            // 资料（F5 文档）：唯一携带真实来源徽章的分支——机器识别未确认 = 'D'
            if kinds.contains(.document) {
                branch(sql: """
                    SELECT id AS id, created_at AS d, COALESCE(title, '') AS title, NULL AS summary, grade AS grade, 'document' AS kind, NULL AS metric_key
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
            return rows.map { Self.entry($0, member: member) }
        }
        // 游标谓词已下推各分支，合并结果即页内序列——直接分页
        return TimelineProjectionRules.page(collected, limit: limit)
    }

    // MARK: - v27 主卡 / 子卡投影（子项目 J · round1 §E.3）

    /// 记录页「主卡 + 折叠子卡」查询：主卡（就诊 / 住院期就诊 / 体检）与**无枢纽叶子**合成一条 UNION ALL 游标分页
    ///（`d DESC, id DESC`，与 `entries(for:)` 同纪律、同 `TimelineCursor`）；子卡按本页主卡 id 批取（≤ limit 张主卡 → 有界 IN 列表，
    /// 每源一次查询），分组 / 子卡序 / 计数交 Domain `TimelineHierarchyRules.group`。子卡日期不参与游标（未来复诊预约不推走主卡）。
    ///
    /// - 旧平铺查询 `entries(for:)` 分支集合与返回**不改**（`M1cAcceptanceTests` 平铺两条断言原样成立）；本方法只追加。
    /// - `filter`：只裁剪叶子分支（与 `entries` 同口径）；主卡恒取（主卡可见性取决于其子卡，由 Domain `visible` 收窄）。
    /// - 成员隔离（BR-001）：每个分支 / 每个子卡源都带 `patient_id = ?`；D 级（`confirmed = 0`）子卡不入。
    /// - 叶子 = `entries` 九分支去 encounter + 「v27 前已确认、无父」的历史子卡（round1 §C 结论 5：不臆造主卡，用户可事后挂接）。
    public func hubPage(patientId member: UUID, filter: TimelineFilter = .all,
                        cursor: TimelineCursor? = nil, limit: Int = 30) async throws -> TimelineHubPage {
        let kinds: Set<TimelineEntryKind> = {
            if case .kinds(let k) = filter { return k }
            return Set(TimelineEntryKind.allCases)
        }()
        let cursorDate = cursor?.date.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude
        let cursorId = cursor?.refID.uuidString ?? ""
        // 叶子装配同读 Domain 单一事实源（FR11.2 V4.05）：Apple 健康导入（`.healthData`）
        // 不入健康档案（专属「健康数据」tab）；新增叶类必须显式入列 recordsArchiveKinds。
        let branches = Self.hubBranches + Self.leaves.filter { kinds.contains($0.kind) && $0.kind.appearsInRecordsArchive }.map(Self.leafBranch)
        let rows: [TimelineHubRow] = try await writer.read { db in
            let sql = branches.joined(separator: "\n UNION ALL\n") + "\n ORDER BY d DESC, id DESC LIMIT ?"
            // 每分支占位符序：patient_id + 游标三元组（date/date/id）——逐分支重复（与 entries 同）
            var args: [DatabaseValueConvertible] = []
            for _ in branches { args.append(contentsOf: [member.uuidString, cursorDate, cursorDate, cursorId] as [DatabaseValueConvertible]) }
            args.append(max(limit, 0) + 1)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                TimelineHubRow(entry: Self.entry(row, member: member), hub: (row["hub"] as String?).flatMap(RecordHub.init(rawValue:)))
            }
        }
        let page = TimelineProjectionRules.page(rows.map(\.entry), limit: limit)
        let pageRows = Array(rows.prefix(page.entries.count))
        let encounterIds = pageRows.filter { $0.hub == .encounter || $0.hub == .hospitalization }.map(\.entry.refID.uuidString)
        let examIds = pageRows.filter { $0.hub == .healthExam }.map(\.entry.refID.uuidString)
        var children: [TimelineChildRow] = []
        if !encounterIds.isEmpty || !examIds.isEmpty {
            children = try await writer.read { db in
                let sources = Self.childSources(encounterIds: encounterIds, examIds: examIds, member: member.uuidString)
                var out: [TimelineChildRow] = []
                for source in sources {
                    for row in try Row.fetchAll(db, sql: source.sql, arguments: StatementArguments(source.args)) {
                        guard let hub = UUID(uuidString: row["hub_id"] as String) else { continue }
                        out.append(TimelineChildRow(hubId: hub, entry: Self.entry(row, member: member)))
                    }
                }
                return out
            }
        }
        return TimelineHubPage(entries: TimelineHierarchyRules.group(rows: pageRows, children: children), nextCursor: page.nextCursor)
    }

    /// 计划文本 / Domain 注释中的旧名（`hubs(for:)`）——同一实现，`hubPage(patientId:)` 为规范名。
    public func hubs(for member: UUID, filter: TimelineFilter = .all,
                     cursor: TimelineCursor? = nil, limit: Int = 30) async throws -> TimelineHubPage {
        try await hubPage(patientId: member, filter: filter, cursor: cursor, limit: limit)
    }

    /// 统一列形态（id / d / title / summary / grade / kind / metric_key）→ 条目；
    /// `entries` 平铺分支与 `hubPage` 主卡/子卡分支共用同一映射（唯一出口，防口径分叉）；
    /// 未知 kind 回落 observation。
    private static func entry(_ row: Row, member: UUID) -> TimelineEntry {
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

    /// 主卡分支（列：id / d / title / summary / grade / kind / metric_key / hub）。就诊带住院态（有已确认住院期 → hospitalization）；
    /// 体检取 exam_date ?? report_date ?? created_at。占位符序：patient_id + 游标三元组，与叶子分支同。
    private static let hubBranches: [String] = [
        """
        SELECT e.id AS id, e.date AS d, e.kind AS title, COALESCE(e.hospital, e.department) AS summary, 'C' AS grade,
               CASE WHEN h.id IS NULL THEN 'encounter' ELSE 'hospitalization' END AS kind, NULL AS metric_key,
               CASE WHEN h.id IS NULL THEN 'encounter' ELSE 'hospitalization' END AS hub
        FROM encounter e LEFT JOIN hospitalization h ON h.encounter_id = e.id AND h.confirmed = 1
        WHERE e.patient_id = ? AND e.deleted_at IS NULL AND (e.date < ? OR (e.date = ? AND e.id < ?))
        """,
        """
        SELECT id AS id, COALESCE(exam_date, report_date, created_at) AS d, COALESCE(org_name, package_name, '') AS title,
               overall_conclusion AS summary, 'C' AS grade, 'healthExam' AS kind, NULL AS metric_key, 'health_exam' AS hub
        FROM health_exam WHERE patient_id = ? AND confirmed = 1
          AND (COALESCE(exam_date, report_date, created_at) < ? OR (COALESCE(exam_date, report_date, created_at) = ? AND id < ?))
        """,
    ]

    /// 叶子分支描述（hub 恒 NULL）：表驱动生成同形 SELECT。`kind` 同时是 SQL 字面量与筛选键（`TimelineEntryKind.rawValue`）。
    private struct Leaf {
        let kind: TimelineEntryKind
        let from: String
        let id: String
        let d: String
        let title: String
        let summary: String
        let grade: String
        let metric: String
        let patient: String
        let extra: String
    }

    /// 无归属子卡判定片段（回执关系投影）：有任一回执挂就诊的检验行 / 表头经子卡源到达，不再作叶子。
    private static let labReportReceiptLinked = """
        EXISTS (SELECT 1 FROM metric_sample m JOIN ocr_card_commit c ON c.entity_id = m.id AND c.entity_table = 'metric_sample' AND c.patient_id = m.patient_id
                WHERE m.lab_report_id = l.id AND m.patient_id = l.patient_id AND c.encounter_id IS NOT NULL)
        OR EXISTS (SELECT 1 FROM lab_result r JOIN ocr_card_commit c ON c.entity_id = r.id AND c.entity_table = 'lab_result' AND c.patient_id = r.patient_id
                WHERE r.lab_report_id = l.id AND r.patient_id = l.patient_id AND c.encounter_id IS NOT NULL)
        """
    /// 原件已经回执 / 卡关系挂到就诊或体检者经子卡源到达，不再作叶子。
    private static let documentHubLinked = """
        d.encounter_id IS NOT NULL
        OR EXISTS (SELECT 1 FROM health_exam h WHERE h.document_file_id = d.id AND h.patient_id = d.patient_id AND h.confirmed = 1)
        OR EXISTS (SELECT 1 FROM ocr_card_commit c WHERE c.document_file_id = d.id AND c.patient_id = d.patient_id
                   AND (c.encounter_id IS NOT NULL OR c.card_kind = 'encounter'))
        """

    private static let leaves: [Leaf] = [
        Leaf(kind: .medication, from: "medication_plan p JOIN medication m ON m.id = p.medication_id", id: "p.id", d: "p.start_date",
             title: "m.generic_name", summary: "m.spec", grade: "'C'", metric: "NULL", patient: "p.patient_id", extra: "1 = 1"),
        Leaf(kind: .observation, from: "observation", id: "id", d: "occurred_at", title: "kind", summary: "description",
             grade: "'C'", metric: "NULL", patient: "patient_id", extra: "1 = 1"),
        Leaf(kind: .selfMeasured, from: "metric_sample", id: "id", d: "measured_at", title: "metric_key", summary: "CAST(value AS TEXT) || ' ' || unit",
             grade: "'C'", metric: "metric_key", patient: "patient_id", extra: "excluded = 0 AND origin = 'manual'"),
        // 设备自动汇入（Apple 健康，FR7.9/FR16.1）**不入健康档案**（FR11.2 V4.05，业主 2026-09-23）：
        // 此前以 `.healthData` 叶参与记录页投影（与手输自测分列防冒充自测）——归属定调后彻底移出，
        // 专属「健康数据」tab（SP-29 展示区/详情页/指标总览）；`metric_sample.origin = 'device'` 数据本身不变。
        // 医院检验点：无表头、无体检、且无回执归属者才是叶子（有表头者经 labReport 子卡呈现，有回执归属者经子卡源到达）
        Leaf(kind: .lab, from: "metric_sample f", id: "f.id", d: "f.measured_at", title: "f.metric_key", summary: "CAST(f.value AS TEXT) || ' ' || f.unit",
             grade: "'C'", metric: "f.metric_key", patient: "f.patient_id",
             extra: "f.excluded = 0 AND f.origin = 'hospital' AND f.lab_report_id IS NULL AND f.health_exam_id IS NULL AND NOT EXISTS (SELECT 1 FROM ocr_card_commit c WHERE c.entity_id = f.id AND c.entity_table = 'metric_sample' AND c.patient_id = f.patient_id AND c.encounter_id IS NOT NULL)"),
        // occurred_at / administered_at 为可空列：COALESCE 到 created_at，NULL 不进 Double 解码（entries 分支沿用原列，不改）
        Leaf(kind: .allergy, from: "allergy_event", id: "id", d: "COALESCE(occurred_at, created_at)", title: "substance", summary: "severity",
             grade: "'C'", metric: "NULL", patient: "patient_id", extra: "1 = 1"),
        // confirmed = 1（BR-003 / ui-ux §5.31）：未确认的 OCR 疫苗行不得以硬编码 'C' 徽章
        // 进入健康档案（其余叶子与子卡源同口径）；未确认行只在待确认队列呈现。
        Leaf(kind: .vaccination, from: "immunization", id: "id", d: "COALESCE(administered_at, created_at)", title: "vaccine_name", summary: "NULL",
             grade: "'C'", metric: "NULL", patient: "patient_id", extra: "encounter_id IS NULL AND confirmed = 1"),
        Leaf(kind: .voiceNote, from: "voice_note", id: "id", d: "occurred_at", title: "''", summary: "body",
             grade: "'C'", metric: "NULL", patient: "patient_id", extra: "in_timeline = 1"),
        Leaf(kind: .healthProblem, from: "health_problem", id: "id", d: "created_at", title: "name", summary: "NULL",
             grade: "'C'", metric: "NULL", patient: "patient_id", extra: "archived = 0"),
        Leaf(kind: .document, from: "document_file d", id: "d.id", d: "d.created_at", title: "COALESCE(d.title, '')", summary: "NULL",
             grade: "d.grade", metric: "NULL", patient: "d.patient_id", extra: "d.status IN ('active','favorite') AND NOT (\(documentHubLinked))"),
        // v27 前已确认、无父的历史子卡（round1 §C 结论 5：叶子、不臆造主卡；用户可在卡详情事后挂接）
        Leaf(kind: .prescription, from: "prescription", id: "id", d: "COALESCE(prescribed_at, created_at)", title: "COALESCE(department, hospital, '')",
             summary: "advice_text", grade: "'C'", metric: "NULL", patient: "patient_id", extra: "confirmed = 1 AND encounter_id IS NULL"),
        Leaf(kind: .claim, from: "claim_item", id: "id", d: "COALESCE(date, created_at)", title: "item_type",
             summary: "CAST(amount AS TEXT) || ' ' || COALESCE(currency, 'CNY')", grade: "'C'", metric: "NULL", patient: "patient_id",
             extra: "confirmed = 1 AND encounter_id IS NULL"),
        Leaf(kind: .labReport, from: "lab_report l", id: "l.id", d: "COALESCE(l.collected_at, l.reported_at, l.created_at)",
             title: "COALESCE(l.test_class_text, l.lab_name, l.hospital, '')", summary: "l.report_no", grade: "'C'", metric: "NULL", patient: "l.patient_id",
             extra: "l.confirmed = 1 AND l.encounter_id IS NULL AND l.health_exam_id IS NULL AND NOT (\(labReportReceiptLinked))"),
        Leaf(kind: .examReport, from: "exam_report", id: "id", d: "COALESCE(exam_at, reported_at, created_at)", title: "report_type",
             summary: "COALESCE(impression, exam_part)", grade: "'C'", metric: "NULL", patient: "patient_id",
             extra: "confirmed = 1 AND encounter_id IS NULL AND health_exam_id IS NULL"),
        Leaf(kind: .diagnosis, from: "diagnosis", id: "id", d: "COALESCE(diagnosed_at, created_at)", title: "name", summary: "code_text",
             grade: "'C'", metric: "NULL", patient: "patient_id", extra: "confirmed = 1 AND encounter_id IS NULL"),
        Leaf(kind: .surgery, from: "surgery", id: "id", d: "COALESCE(surgery_at, created_at)", title: "surgery_name", summary: "surgeon",
             grade: "'C'", metric: "NULL", patient: "patient_id", extra: "confirmed = 1 AND encounter_id IS NULL"),
        Leaf(kind: .treatmentRecord, from: "treatment_record", id: "id", d: "COALESCE(treated_at, created_at)", title: "treatment_type", summary: "content",
             grade: "'C'", metric: "NULL", patient: "patient_id", extra: "confirmed = 1 AND encounter_id IS NULL"),
        Leaf(kind: .appointment, from: "appointment", id: "id", d: "starts_at", title: "COALESCE(hospital, '')", summary: "department",
             grade: "'C'", metric: "NULL", patient: "patient_id", extra: "encounter_id IS NULL"),
    ]

    private static func leafBranch(_ l: Leaf) -> String {
        "SELECT \(l.id) AS id, \(l.d) AS d, \(l.title) AS title, \(l.summary) AS summary, \(l.grade) AS grade, '\(l.kind.rawValue)' AS kind, "
            + "\(l.metric) AS metric_key, NULL AS hub FROM \(l.from) WHERE \(l.patient) = ? AND \(l.extra) AND (\(l.d) < ? OR (\(l.d) = ? AND \(l.id) < ?))"
    }

    /// 子卡源：列 hub_id / id / d / title / summary / grade / kind / metric_key。IN 列表按 id 数生成占位；空列表跳过该源。
    /// 就诊子卡：FK 直连（v26 表 encounter_id）∪ 回执关系投影（检验表头经其行回执、无表头历史检验行）；预约经 encounter_id，
    /// 提醒经 source_table = encounter / 经预约到达就诊；原件经 document_file.encounter_id ∪ 回执 encounter_id。
    /// 体检子卡：检验 / 检查表头经 health_exam_id；结论聚合为一条子卡（refID = 体检 id，title = 条数，summary = 首条原文）；
    /// 原件经 health_exam.document_file_id；提醒经 source_table = health_exam。
    private static func childSources(encounterIds: [String], examIds: [String], member: String) -> [(sql: String, args: [DatabaseValueConvertible])] {
        func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }
        var sources: [(sql: String, args: [DatabaseValueConvertible])] = []
        if !encounterIds.isEmpty {
            let e = marks(encounterIds.count)
            let a: [DatabaseValueConvertible] = [member] + encounterIds
            sources.append(("SELECT encounter_id AS hub_id, id, COALESCE(admit_at, discharge_at, created_at) AS d, COALESCE(hospital, '') AS title, discharge_diagnosis_text AS summary, 'C' AS grade, 'hospitalization' AS kind, NULL AS metric_key FROM hospitalization WHERE patient_id = ? AND confirmed = 1 AND encounter_id IN (\(e))", a))
            sources.append(("SELECT encounter_id AS hub_id, id, COALESCE(diagnosed_at, created_at) AS d, name AS title, code_text AS summary, 'C' AS grade, 'diagnosis' AS kind, NULL AS metric_key FROM diagnosis WHERE patient_id = ? AND confirmed = 1 AND encounter_id IN (\(e))", a))
            sources.append(("SELECT p.encounter_id AS hub_id, p.id, COALESCE(p.prescribed_at, p.created_at) AS d, COALESCE((SELECT l.printed_name FROM prescription_line l WHERE l.prescription_id = p.id ORDER BY l.ordinal LIMIT 1), p.department, p.hospital, '') AS title, CAST((SELECT COUNT(*) FROM prescription_line l WHERE l.prescription_id = p.id) AS TEXT) AS summary, 'C' AS grade, 'prescription' AS kind, NULL AS metric_key FROM prescription p WHERE p.patient_id = ? AND p.confirmed = 1 AND p.encounter_id IN (\(e))", a))
            // 检验表头：FK 直连 ∪ 经任一行回执归属（v26 回填表头无 encounter_id，EncounterStore.linkedCards 同口径）
            sources.append(("SELECT l.encounter_id AS hub_id, l.id, COALESCE(l.collected_at, l.reported_at, l.created_at) AS d, COALESCE(l.test_class_text, l.lab_name, l.hospital, '') AS title, l.report_no AS summary, 'C' AS grade, 'labReport' AS kind, NULL AS metric_key FROM lab_report l WHERE l.patient_id = ? AND l.confirmed = 1 AND l.encounter_id IN (\(e))"
                + " UNION SELECT c.encounter_id, l.id, COALESCE(l.collected_at, l.reported_at, l.created_at), COALESCE(l.test_class_text, l.lab_name, l.hospital, ''), l.report_no, 'C', 'labReport', NULL FROM lab_report l JOIN metric_sample m ON m.lab_report_id = l.id AND m.patient_id = l.patient_id JOIN ocr_card_commit c ON c.entity_id = m.id AND c.entity_table = 'metric_sample' AND c.patient_id = l.patient_id WHERE l.patient_id = ? AND l.confirmed = 1 AND c.encounter_id IN (\(e))"
                + " UNION SELECT c.encounter_id, l.id, COALESCE(l.collected_at, l.reported_at, l.created_at), COALESCE(l.test_class_text, l.lab_name, l.hospital, ''), l.report_no, 'C', 'labReport', NULL FROM lab_report l JOIN lab_result r ON r.lab_report_id = l.id AND r.patient_id = l.patient_id JOIN ocr_card_commit c ON c.entity_id = r.id AND c.entity_table = 'lab_result' AND c.patient_id = l.patient_id WHERE l.patient_id = ? AND l.confirmed = 1 AND c.encounter_id IN (\(e))", a + a + a))
            // 无表头的历史检验行：只经回执关系到达（有表头者由上一源以报告呈现，不逐行重复）
            sources.append(("SELECT c.encounter_id AS hub_id, f.id, f.measured_at AS d, f.metric_key AS title, CAST(f.value AS TEXT) || ' ' || f.unit AS summary, 'C' AS grade, 'lab' AS kind, f.metric_key AS metric_key FROM metric_sample f JOIN ocr_card_commit c ON c.entity_id = f.id AND c.entity_table = 'metric_sample' AND c.patient_id = f.patient_id WHERE f.patient_id = ? AND f.excluded = 0 AND f.lab_report_id IS NULL AND c.encounter_id IN (\(e))", a))
            sources.append(("SELECT encounter_id AS hub_id, id, COALESCE(exam_at, reported_at, created_at) AS d, report_type AS title, COALESCE(impression, exam_part) AS summary, 'C' AS grade, 'examReport' AS kind, NULL AS metric_key FROM exam_report WHERE patient_id = ? AND confirmed = 1 AND encounter_id IN (\(e))", a))
            sources.append(("SELECT encounter_id AS hub_id, id, COALESCE(date, created_at) AS d, item_type AS title, CAST(amount AS TEXT) || ' ' || COALESCE(currency, 'CNY') AS summary, 'C' AS grade, 'claim' AS kind, NULL AS metric_key FROM claim_item WHERE patient_id = ? AND confirmed = 1 AND encounter_id IN (\(e))", a))
            sources.append(("SELECT encounter_id AS hub_id, id, COALESCE(administered_at, created_at) AS d, vaccine_name AS title, provider AS summary, 'C' AS grade, 'vaccination' AS kind, NULL AS metric_key FROM immunization WHERE patient_id = ? AND confirmed = 1 AND encounter_id IN (\(e))", a))
            sources.append(("SELECT encounter_id AS hub_id, id, COALESCE(surgery_at, created_at) AS d, surgery_name AS title, surgeon AS summary, 'C' AS grade, 'surgery' AS kind, NULL AS metric_key FROM surgery WHERE patient_id = ? AND confirmed = 1 AND encounter_id IN (\(e))", a))
            sources.append(("SELECT encounter_id AS hub_id, id, COALESCE(treated_at, created_at) AS d, treatment_type AS title, content AS summary, 'C' AS grade, 'treatmentRecord' AS kind, NULL AS metric_key FROM treatment_record WHERE patient_id = ? AND confirmed = 1 AND encounter_id IN (\(e))", a))
            sources.append(("SELECT encounter_id AS hub_id, id, starts_at AS d, COALESCE(hospital, '') AS title, department AS summary, 'C' AS grade, 'appointment' AS kind, NULL AS metric_key FROM appointment WHERE patient_id = ? AND encounter_id IN (\(e))", a))
            sources.append(("SELECT source_id AS hub_id, id, at_date AS d, title, kind AS summary, 'C' AS grade, 'reminder' AS kind, NULL AS metric_key FROM reminder WHERE patient_id = ? AND status = 'active' AND source_table = 'encounter' AND source_id IN (\(e))"
                + " UNION SELECT a.encounter_id, r.id, r.at_date, r.title, r.kind, 'C', 'reminder', NULL FROM reminder r JOIN appointment a ON a.id = r.source_id AND a.patient_id = r.patient_id WHERE r.patient_id = ? AND r.status = 'active' AND r.source_table = 'appointment' AND a.encounter_id IN (\(e))", a + a))
            sources.append(("SELECT d.encounter_id AS hub_id, d.id, d.created_at AS d, COALESCE(d.title, '') AS title, d.doc_type_key AS summary, d.grade AS grade, 'document' AS kind, NULL AS metric_key FROM document_file d WHERE d.patient_id = ? AND d.status IN ('active','favorite') AND d.encounter_id IN (\(e))"
                + " UNION SELECT c.encounter_id, d.id, d.created_at, COALESCE(d.title, ''), d.doc_type_key, d.grade, 'document', NULL FROM document_file d JOIN ocr_card_commit c ON c.document_file_id = d.id AND c.patient_id = d.patient_id WHERE d.patient_id = ? AND d.status IN ('active','favorite') AND c.encounter_id IN (\(e))"
                + " UNION SELECT c.entity_id, d.id, d.created_at, COALESCE(d.title, ''), d.doc_type_key, d.grade, 'document', NULL FROM document_file d JOIN ocr_card_commit c ON c.document_file_id = d.id AND c.patient_id = d.patient_id WHERE d.patient_id = ? AND d.status IN ('active','favorite') AND c.card_kind = 'encounter' AND c.entity_id IN (\(e))", a + a + a))
        }
        if !examIds.isEmpty {
            let x = marks(examIds.count)
            let a: [DatabaseValueConvertible] = [member] + examIds
            sources.append(("SELECT health_exam_id AS hub_id, id, COALESCE(collected_at, reported_at, created_at) AS d, COALESCE(test_class_text, lab_name, hospital, '') AS title, report_no AS summary, 'C' AS grade, 'labReport' AS kind, NULL AS metric_key FROM lab_report WHERE patient_id = ? AND confirmed = 1 AND health_exam_id IN (\(x))", a))
            sources.append(("SELECT health_exam_id AS hub_id, id, COALESCE(exam_at, reported_at, created_at) AS d, report_type AS title, COALESCE(impression, exam_part) AS summary, 'C' AS grade, 'examReport' AS kind, NULL AS metric_key FROM exam_report WHERE patient_id = ? AND confirmed = 1 AND health_exam_id IN (\(x))", a))
            // 结论聚合为一条子卡（refID = 体检 id，title = 条数，summary = 首条原文）；详情页逐条呈现
            sources.append(("SELECT health_exam_id AS hub_id, health_exam_id AS id, MAX(created_at) AS d, CAST(COUNT(*) AS TEXT) AS title, MIN(content) AS summary, 'C' AS grade, 'clinicalConclusion' AS kind, NULL AS metric_key FROM clinical_conclusion WHERE patient_id = ? AND health_exam_id IN (\(x)) GROUP BY health_exam_id", a))
            sources.append(("SELECT h.id AS hub_id, d.id, d.created_at AS d, COALESCE(d.title, '') AS title, d.doc_type_key AS summary, d.grade AS grade, 'document' AS kind, NULL AS metric_key FROM document_file d JOIN health_exam h ON h.document_file_id = d.id AND h.patient_id = d.patient_id WHERE d.patient_id = ? AND d.status IN ('active','favorite') AND h.id IN (\(x))", a))
            sources.append(("SELECT source_id AS hub_id, id, at_date AS d, title, kind AS summary, 'C' AS grade, 'reminder' AS kind, NULL AS metric_key FROM reminder WHERE patient_id = ? AND status = 'active' AND source_table = 'health_exam' AND source_id IN (\(x))", a))
        }
        return sources
    }
}
#endif
