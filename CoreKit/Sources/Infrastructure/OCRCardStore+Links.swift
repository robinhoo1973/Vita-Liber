#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

extension OCRCardStore {
    public struct SourcePage: Sendable, Identifiable {
        public let documentId: UUID
        public let pageIndex: Int
        public let title: String?
        public var id: String { "\(documentId.uuidString)#p\(pageIndex)" }
    }
    public struct CardDetail: Sendable {
        public let kind: String
        public let entityId: UUID
        public let patientId: UUID
        public let fields: [FieldDraft]
        public let sources: [SourcePage]
        public let encounterIDs: [UUID]
        public let relationshipEditable: Bool
        /// v25（§C.6）：处方行（按 ordinal）；其他卡类为空。行详情经 `lineDetail(lineId:patientId:)`。
        public let lines: [PrescriptionLine]
        /// v26（§C.2）：住院期叙事（kind = hospitalization）。
        public var hospitalization: Hospitalization? = nil
        /// v26（§C.3）：同卡诊断清单（kind = diagnosis；含本实体，按 ordinal）。
        public var diagnoses: [Diagnosis] = []
        /// v26（§C.4）：检查报告（kind = exam_report）。
        public var examReport: ExamReport? = nil
        /// v26（§C.5）：检验报告 = 表头 + 数值行 + 定性行（kind = lab_report；kind = metric_sample 且行回指表头时亦附带）。
        public var labReport: LabReportDetail? = nil
    }

    /// 检验报告读面（§C.5）：数值行来自 `metric_sample`（趋势点，按落库序）、定性行来自 `lab_result`（按 ordinal）；
    /// `abnormalFlag/resultText/referenceText` 一律报告原文——只呈现、不着色、不解释（BR-004/012）。
    public struct LabReportDetail: Sendable {
        public let report: LabReport
        public let samples: [LabSampleRow]
        public let results: [LabResult]
    }

    /// 只读详情卡类 = 可确认卡类 ∪ `lab_report`（检验表头不是卡类，是同卡数值/定性行的读面聚合入口）。
    public static let detailKinds: Set<String> = supportedKinds.union(["lab_report"])

    /// 详情卡类 → 回执 `card_kind`（`lab_report` 详情聚合的是 metric_sample 卡的回执）。
    static func receiptCardKind(forDetailKind kind: String) -> String {
        kind == "lab_report" ? "metric_sample" : kind
    }
    /// 处方行详情：行 + 表头卡 + 该行自己的来源页（行回执；v25 回填行沿表头回执，同页即同来源）。
    public struct LineDetail: Sendable {
        public let line: PrescriptionLine
        public let header: CardDetail
        public let source: SourcePage?
    }

    /// 表头表 `TEXT` 列 → 详情字段目录（`CardKindRegistry` 派生）：模板键 → 列名（注册表键与列名不同拼写处在此对齐）。
    /// 表头目录 = 共享必填 ∪ `optionalCatalog(rowLevel: false)`；无行表的卡类（药品/检验样本）行键即实体列，一并纳入；
    /// 日期键 / REAL·INTEGER 列（另按类型单独追加）/ 非列键剔除；表中不存在的列由调用方 `hasColumn` 跳过。
    static func detailColumns(kind: String) -> [(key: String, column: String)] {
        guard let entry = CardKindRegistry.entry(for: kind) else { return [] }
        var renamed: [String: String] = ["fee_type": "fee_type_text", "insurance_type": "insurance_type_text",
                                         // v26：模板键 → `*_text` 列（§C.2 / §C.3 / §C.5）
                                         "admit_route": "admit_route_text", "payment_type": "payment_type_text", "discharge_way": "discharge_way_text",
                                         "admit_diagnosis": "admit_diagnosis_text", "discharge_diagnosis": "discharge_diagnosis_text",
                                         "take_home_drugs": "take_home_drugs_text", "code_system": "code_system_text", "test_class": "test_class_text"]
        if kind == "metric_sample" { renamed["hospital"] = "ref_source_label" }
        // 日期 / REAL / INTEGER 列另按类型追加（见 detail）；非列键剔除。
        let excluded: Set<String> = ["prescribed_at", "date", "measured_at", "administered_at", "kind",
                                     "illness_summary", "amount", "dose_number", "total_amount",
                                     "reimbursed_amount", "out_of_pocket", "personal_account_amount", "value", "ref_low", "ref_high", "metric_key",
                                     "admit_at", "discharge_at", "summary_date", "inpatient_times", "actual_days", "total_cost",
                                     "diagnosed_at", "exam_at", "reported_at", "collected_at", "received_at"]
        var keys = entry.sharedRequired.union(CardKindRegistry.optionalCatalog(kind: kind, present: [], rowLevel: false))
        if lineTable(for: kind) == nil { keys.formUnion(entry.rowAllowed) }
        return keys.subtracting(excluded).sorted().map { ($0, renamed[$0] ?? $0) }
    }

    /// 检验表头列 → 详情字段目录（`lab_report` 详情卡类；键与 CardKindRegistry.metric_sample 共享键同拼写）。
    static let labReportColumns: [(key: String, column: String)] = [
        ("hospital", "hospital"), ("department", "department"), ("lab_name", "lab_name"), ("report_no", "report_no"),
        ("specimen_type", "specimen_type"), ("specimen_no", "specimen_no"), ("test_class", "test_class_text"), ("clinical_diagnosis", "clinical_diagnosis"),
        ("send_doctor", "send_doctor"), ("test_doctor", "test_doctor"), ("review_doctor", "review_doctor"),
    ]

    /// 已确认卡的真实字段 + 独立原件页链接；D级草稿不参与该读面。
    public func detail(kind: String, entityId: UUID, patientId: UUID) async throws -> CardDetail {
        guard Self.detailKinds.contains(kind) else { throw StoreError.invalidCard }
        return try await writer.read { db in
            try Self.detail(kind: kind, entityId: entityId, patientId: patientId, db: db)
        }
    }

    static func detail(kind: String, entityId: UUID, patientId: UUID, db: Database) throws -> CardDetail {
        let table = factTable(for: kind)
        guard let fact = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id = ? AND patient_id = ?",
                                         arguments: [entityId.uuidString, patientId.uuidString]) else { throw StoreError.invalidCard }
        if ["prescription", "claim_item", "immunization", "hospitalization", "diagnosis", "exam_report", "lab_report"].contains(kind),
           (fact["confirmed"] as Int?) != 1 { throw StoreError.invalidCard }
        if kind == "encounter", (fact["deleted_at"] as Double?) != nil { throw StoreError.invalidCard }
        let cardKind = receiptCardKind(forDetailKind: kind)
        let scope = receiptScope(kind: kind, headerId: entityId.uuidString, patientId: patientId.uuidString)
        let receipts = try Row.fetchAll(db, sql: """
            SELECT * FROM ocr_card_commit WHERE patient_id = ? AND card_kind = ? AND \(scope.sql)
            ORDER BY document_file_id, page_index, row_id
            """, arguments: receiptArguments([patientId.uuidString, cardKind], scope))
        var sources: [SourcePage] = [], encounters = Set<UUID>()
        for receipt in receipts {
            try validateReceipt(receipt, db: db)
            guard let document = UUID(uuidString: receipt["document_file_id"] as String) else { throw StoreError.corruptReceipt }
            let page = SourcePage(documentId: document, pageIndex: receipt["page_index"],
                title: try String.fetchOne(db, sql: "SELECT title FROM document_file WHERE id = ? AND patient_id = ?", arguments: [document.uuidString, patientId.uuidString]))
            if !sources.contains(where: { $0.id == page.id }) { sources.append(page) }
            if let id = (receipt["encounter_id"] as String?).flatMap(UUID.init(uuidString:)) { encounters.insert(id) }
        }
        if kind == "encounter" { encounters.insert(entityId) }
        if ["prescription", "claim_item", "immunization", "hospitalization", "diagnosis", "exam_report", "lab_report"].contains(kind),
           let id = (fact["encounter_id"] as String?).flatMap(UUID.init(uuidString:)) { encounters.insert(id) }
        var fields: [FieldDraft] = []
        func append(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { fields.append(.init(key: key, value: value, grade: .userConfirmed)) }
        }
        if kind == "lab_report" {
            for (key, column) in labReportColumns { append(key, fact[column] as String?) }
        } else {
            for (key, column) in detailColumns(kind: kind) where fact.hasColumn(column) { append(key, fact[column] as String?) }
        }
        if kind == "claim_item" {
            for key in ["amount", "reimbursed_amount", "out_of_pocket", "personal_account_amount"] {
                append(key, (fact[key] as Double?).map(String.init(describing:)))
            }
        }
        if kind == "prescription" { append("total_amount", (fact["total_amount"] as Double?).map(String.init(describing:))) }
        if kind == "metric_sample" {
            for key in ["value", "ref_low", "ref_high"] { append(key, (fact[key] as Double?).map(String.init(describing:))) }
        }
        if kind == "immunization" { append("dose_number", (fact["dose_number"] as Int?).map(String.init)) }
        // v26：日期 / 整数 / 金额列按卡字段同型追加（日期 yyyy-MM-dd，数字原样；展示层再本地化）。
        switch kind {
        case "hospitalization":
            for key in ["admit_at", "discharge_at", "summary_date"] { append(key, dateString(fact[key] as Double?)) }
            for key in ["inpatient_times", "actual_days"] { append(key, (fact[key] as Int?).map(String.init)) }
            append("total_cost", (fact["total_cost"] as Double?).map(String.init(describing:)))
        case "diagnosis":
            append("diagnosed_at", dateString(fact["diagnosed_at"] as Double?))
        case "exam_report":
            for key in ["exam_at", "reported_at"] { append(key, dateString(fact[key] as Double?)) }
        case "lab_report":
            for key in ["collected_at", "received_at", "reported_at"] { append(key, dateString(fact[key] as Double?)) }
        default: break
        }
        var lines: [PrescriptionLine] = []
        if kind == "prescription" {
            lines = try Row.fetchAll(db, sql: "SELECT * FROM prescription_line WHERE prescription_id = ? AND patient_id = ? ORDER BY ordinal",
                                     arguments: [entityId.uuidString, patientId.uuidString]).map(prescriptionLine(from:))
        }
        let pending = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM pending_card p JOIN ocr_card_commit c ON c.card_id = p.id
            WHERE c.patient_id = ? AND c.card_kind = ? AND \(scope.sql) AND p.status IN ('pending','in_progress')
            """, arguments: receiptArguments([patientId.uuidString, cardKind], scope)) ?? 0
        let active = try encounters.filter { id in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM encounter WHERE id = ? AND patient_id = ? AND deleted_at IS NULL", arguments: [id.uuidString, patientId.uuidString]) == 1
        }.sorted { $0.uuidString < $1.uuidString }
        // 住院期随就诊而生（UNIQUE(encounter_id)），归属不可单独改挂——其余卡类在无待办回执时可改挂。
        var result = CardDetail(kind: kind, entityId: entityId, patientId: patientId, fields: fields, sources: sources,
                                encounterIDs: active, relationshipEditable: !["encounter", "hospitalization"].contains(kind) && pending == 0, lines: lines)
        switch kind {
        case "hospitalization":
            result.hospitalization = try hospitalization(from: fact)
        case "diagnosis":
            // 同卡诊断清单：本实体的回执所属卡的全部诊断行（手工/无回执 → 只有本行）。
            let cardIds = try String.fetchAll(db, sql: "SELECT card_id FROM ocr_card_commit WHERE entity_table = 'diagnosis' AND entity_id = ? AND patient_id = ?",
                                              arguments: [entityId.uuidString, patientId.uuidString])
            var rows = [try diagnosis(from: fact)]
            if let card = cardIds.first {
                rows = try Row.fetchAll(db, sql: """
                    SELECT d.* FROM diagnosis d JOIN ocr_card_commit c ON c.entity_id = d.id AND c.entity_table = 'diagnosis' AND c.patient_id = d.patient_id
                    WHERE c.card_id = ? AND d.patient_id = ? AND d.confirmed = 1 ORDER BY d.ordinal, d.created_at
                    """, arguments: [card, patientId.uuidString]).map(diagnosis(from:))
            }
            result.diagnoses = rows
        case "exam_report":
            result.examReport = try examReport(from: fact)
        case "lab_report":
            result.labReport = try labReportDetail(reportId: entityId.uuidString, patientId: patientId.uuidString, db: db)
        case "metric_sample":
            if let report: String = fact["lab_report_id"] {
                result.labReport = try labReportDetail(reportId: report, patientId: patientId.uuidString, db: db)
            }
        default: break
        }
        return result
    }

    /// 检验报告聚合读面：表头 + 数值行（metric_sample，按落库序）+ 定性行（lab_result，按 ordinal）；成员隔离逐表带 patient_id。
    static func labReportDetail(reportId: String, patientId: String, db: Database) throws -> LabReportDetail? {
        guard let header = try Row.fetchOne(db, sql: "SELECT * FROM lab_report WHERE id = ? AND patient_id = ?", arguments: [reportId, patientId]) else { return nil }
        let samples = try Row.fetchAll(db, sql: """
            SELECT * FROM metric_sample WHERE lab_report_id = ? AND patient_id = ? ORDER BY created_at, rowid
            """, arguments: [reportId, patientId]).map(labSampleRow(from:))
        let results = try Row.fetchAll(db, sql: "SELECT * FROM lab_result WHERE lab_report_id = ? AND patient_id = ? ORDER BY ordinal",
                                       arguments: [reportId, patientId]).map(labResult(from:))
        return LabReportDetail(report: try labReport(from: header), samples: samples, results: results)
    }

    /// 处方行详情（SP 行详情路由）：行 + 表头卡 + 来源页。成员隔离：行 `patient_id` 与表头 `patient_id` 都必须等于请求成员，
    /// 否则一律 `invalidCard`（不区分「不存在」与「他人的」，不泄露存在性）。
    public func lineDetail(lineId: UUID, patientId: UUID) async throws -> LineDetail {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT l.* FROM prescription_line l JOIN prescription h ON h.id = l.prescription_id AND h.patient_id = l.patient_id
                WHERE l.id = ? AND l.patient_id = ?
                """, arguments: [lineId.uuidString, patientId.uuidString]) else { throw StoreError.invalidCard }
            let line = try Self.prescriptionLine(from: row)
            let header = try Self.detail(kind: "prescription", entityId: line.prescriptionId, patientId: patientId, db: db)
            var source: SourcePage? = nil
            if let receipt = try Row.fetchOne(db, sql: """
                SELECT * FROM ocr_card_commit WHERE patient_id = ? AND card_kind = 'prescription'
                  AND ((entity_table = 'prescription_line' AND entity_id = ?) OR (entity_table = 'prescription' AND entity_id = ? AND row_id = ?))
                ORDER BY created_at LIMIT 1
                """, arguments: [patientId.uuidString, lineId.uuidString, line.prescriptionId.uuidString, (line.sourceRowId ?? lineId).uuidString]) {
                try Self.validateReceipt(receipt, db: db)
                guard let document = UUID(uuidString: receipt["document_file_id"] as String) else { throw StoreError.corruptReceipt }
                source = header.sources.first { $0.documentId == document && $0.pageIndex == (receipt["page_index"] as Int) }
                    ?? SourcePage(documentId: document, pageIndex: receipt["page_index"], title: nil)
            }
            return LineDetail(line: line, header: header, source: source)
        }
    }

    /// 原件的所有已确认实体卡供反向导航。仅查该原件，不把整库备份查询用于详情热路径。
    /// v25：行回执（prescription_line / claim_line）折叠为其表头 `(kind, headerId)`——反向导航到卡，不到行。
    /// v26：检验行回执（metric_sample / lab_result）回指表头时折叠为 `("lab_report", reportId)`（一张检验卡 = 一份报告）；
    /// 无表头的历史数值行仍逐行 `("metric_sample", sampleId)`。
    public func cards(documentId: UUID, patientId: UUID) async throws -> [(kind: String, id: UUID)] {
        try await writer.read { db in
            guard try String.fetchOne(db, sql: "SELECT patient_id FROM document_file WHERE id = ?", arguments: [documentId.uuidString]) == patientId.uuidString else { throw StoreError.invalidCard }
            var seen = Set<String>()
            var result: [(kind: String, id: UUID)] = []
            for row in try Row.fetchAll(db, sql: "SELECT * FROM ocr_card_commit WHERE document_file_id = ? AND patient_id = ? ORDER BY card_kind, entity_id",
                                        arguments: [documentId.uuidString, patientId.uuidString]) {
                var kind: String = row["card_kind"]
                var header = try Self.headerId(of: row, db: db)
                if kind == "metric_sample" {
                    let table: String = row["entity_table"]
                    if table == "lab_result" || table == "metric_sample",
                       let report = try String.fetchOne(db, sql: "SELECT lab_report_id FROM \(table) WHERE id = ? AND patient_id = ?",
                                                        arguments: [header, patientId.uuidString]) {
                        kind = "lab_report"; header = report
                    } else if table == "lab_result" {
                        continue   // 定性行无表头不可达（DDL NOT NULL，理论不可能）；不伪造入口
                    }
                }
                guard let id = UUID(uuidString: header), seen.insert("\(kind)/\(id.uuidString)").inserted else { continue }
                result.append((kind, id))
            }
            return result.sorted { ($0.kind, $0.id.uuidString) < ($1.kind, $1.id.uuidString) }
        }
    }

    public func associatedEncounters(documentId: UUID, patientId: UUID) async throws -> [UUID] {
        try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT e.id FROM encounter e JOIN (
                  SELECT encounter_id AS id FROM document_file WHERE id = ? AND patient_id = ?
                  UNION SELECT COALESCE(encounter_id, CASE WHEN card_kind = 'encounter' THEN entity_id END) AS id
                    FROM ocr_card_commit WHERE document_file_id = ? AND patient_id = ?
                  UNION SELECT encounter_id AS id FROM prescription WHERE document_file_id = ? AND patient_id = ? AND confirmed = 1
                  UNION SELECT encounter_id AS id FROM claim_item WHERE document_file_id = ? AND patient_id = ? AND confirmed = 1
                  UNION SELECT encounter_id AS id FROM hospitalization WHERE document_file_id = ? AND patient_id = ? AND confirmed = 1
                  UNION SELECT encounter_id AS id FROM diagnosis WHERE document_file_id = ? AND patient_id = ? AND confirmed = 1
                  UNION SELECT encounter_id AS id FROM exam_report WHERE document_file_id = ? AND patient_id = ? AND confirmed = 1
                  UNION SELECT encounter_id AS id FROM lab_report WHERE document_file_id = ? AND patient_id = ? AND confirmed = 1
                ) r ON r.id = e.id WHERE e.patient_id = ? AND e.deleted_at IS NULL ORDER BY e.date DESC
                """, arguments: [documentId.uuidString, patientId.uuidString, documentId.uuidString, patientId.uuidString,
                    documentId.uuidString, patientId.uuidString, documentId.uuidString, patientId.uuidString,
                    documentId.uuidString, patientId.uuidString, documentId.uuidString, patientId.uuidString,
                    documentId.uuidString, patientId.uuidString, documentId.uuidString, patientId.uuidString, patientId.uuidString])
                .compactMap(UUID.init(uuidString:))
        }
    }

    /// 改挂就诊：事实表 `encounter_id`（处方/票据/免疫）+ 该表头全部回执（表头回执 ∪ 行回执）的关系投影同事务更新。
    /// 两条 UPDATE 合计零行 → `invalidAssociation`（无回执又无 encounter_id 列的实体没有可改的关系，不伪装成功、不写审计）。
    /// v26：diagnosis / exam_report / lab_report（表头 + 其全部行回执）同样可改挂；hospitalization 随就诊而生（UNIQUE(encounter_id)），
    /// 不可单独改挂——一律 `invalidCard`。
    public func associate(kind: String, entityId: UUID, patientId: UUID, encounterId: UUID?) async throws {
        guard Self.detailKinds.contains(kind), !["encounter", "hospitalization"].contains(kind) else { throw StoreError.invalidCard }
        let table = Self.factTable(for: kind)
        let cardKind = Self.receiptCardKind(forDetailKind: kind)
        let confirmedKinds: Set<String> = ["prescription", "claim_item", "immunization", "diagnosis", "exam_report", "lab_report"]
        try await writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id = ? AND patient_id = ?",
                                            arguments: [entityId.uuidString, patientId.uuidString]) else { throw StoreError.invalidCard }
            if confirmedKinds.contains(kind), (row["confirmed"] as Int?) != 1 { throw StoreError.invalidCard }
            if let encounterId {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM encounter WHERE id = ? AND patient_id = ? AND deleted_at IS NULL",
                                       arguments: [encounterId.uuidString, patientId.uuidString]) == 1 else { throw StoreError.invalidAssociation }
            }
            let scope = Self.receiptScope(kind: kind, headerId: entityId.uuidString, patientId: patientId.uuidString)
            let pending = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM pending_card p JOIN ocr_card_commit c ON c.card_id = p.id
                WHERE c.patient_id = ? AND c.card_kind = ? AND \(scope.sql) AND p.status IN ('pending','in_progress')
                """, arguments: Self.receiptArguments([patientId.uuidString, cardKind], scope)) ?? 0
            guard pending == 0 else { throw StoreError.committedDataChanged }
            var changed = 0
            if confirmedKinds.contains(kind) {
                try db.execute(sql: "UPDATE \(table) SET encounter_id = ?, updated_at = ? WHERE id = ? AND patient_id = ?",
                               arguments: [encounterId?.uuidString, Date().timeIntervalSince1970, entityId.uuidString, patientId.uuidString])
                changed += db.changesCount
            }
            try db.execute(sql: "UPDATE ocr_card_commit SET encounter_id = ? WHERE patient_id = ? AND card_kind = ? AND \(scope.sql)",
                           arguments: Self.receiptArguments([encounterId?.uuidString, patientId.uuidString, cardKind], scope))
            changed += db.changesCount
            guard changed >= 1 else { throw StoreError.invalidAssociation }
            let meta = String(decoding: try JSONEncoder().encode(["relationship": "encounter", "linked": encounterId == nil ? "false" : "true"]), as: UTF8.self)
            try AuditLogWriter.insert(action: "update", entityType: kind, entityId: entityId.uuidString, actorLocal: "owner", meta: meta, db: db)
        }
    }
}
#endif
