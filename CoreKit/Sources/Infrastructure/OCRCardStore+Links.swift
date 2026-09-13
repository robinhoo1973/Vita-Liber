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
        var renamed: [String: String] = ["fee_type": "fee_type_text", "insurance_type": "insurance_type_text"]
        if kind == "metric_sample" { renamed["hospital"] = "ref_source_label" }
        let excluded: Set<String> = ["prescribed_at", "date", "measured_at", "administered_at", "kind",
                                     "illness_summary", "amount", "dose_number", "total_amount",
                                     "reimbursed_amount", "out_of_pocket", "personal_account_amount", "value", "ref_low", "ref_high", "metric_key"]
        var keys = entry.sharedRequired.union(CardKindRegistry.optionalCatalog(kind: kind, present: [], rowLevel: false))
        if lineTable(for: kind) == nil { keys.formUnion(entry.rowAllowed) }
        return keys.subtracting(excluded).sorted().map { ($0, renamed[$0] ?? $0) }
    }

    /// 已确认卡的真实字段 + 独立原件页链接；D级草稿不参与该读面。
    public func detail(kind: String, entityId: UUID, patientId: UUID) async throws -> CardDetail {
        guard Self.supportedKinds.contains(kind) else { throw StoreError.invalidCard }
        return try await writer.read { db in
            try Self.detail(kind: kind, entityId: entityId, patientId: patientId, db: db)
        }
    }

    static func detail(kind: String, entityId: UUID, patientId: UUID, db: Database) throws -> CardDetail {
        let table = factTable(for: kind)
        guard let fact = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id = ? AND patient_id = ?",
                                         arguments: [entityId.uuidString, patientId.uuidString]) else { throw StoreError.invalidCard }
        if ["prescription", "claim_item", "immunization"].contains(kind), (fact["confirmed"] as Int?) != 1 { throw StoreError.invalidCard }
        if kind == "encounter", (fact["deleted_at"] as Double?) != nil { throw StoreError.invalidCard }
        let scope = receiptScope(kind: kind, headerId: entityId.uuidString, patientId: patientId.uuidString)
        let receipts = try Row.fetchAll(db, sql: """
            SELECT * FROM ocr_card_commit WHERE patient_id = ? AND card_kind = ? AND \(scope.sql)
            ORDER BY document_file_id, page_index, row_id
            """, arguments: receiptArguments([patientId.uuidString, kind], scope))
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
        if ["prescription", "claim_item", "immunization"].contains(kind), let id = (fact["encounter_id"] as String?).flatMap(UUID.init(uuidString:)) { encounters.insert(id) }
        var fields: [FieldDraft] = []
        func append(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { fields.append(.init(key: key, value: value, grade: .userConfirmed)) }
        }
        for (key, column) in detailColumns(kind: kind) where fact.hasColumn(column) { append(key, fact[column] as String?) }
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
        var lines: [PrescriptionLine] = []
        if kind == "prescription" {
            lines = try Row.fetchAll(db, sql: "SELECT * FROM prescription_line WHERE prescription_id = ? AND patient_id = ? ORDER BY ordinal",
                                     arguments: [entityId.uuidString, patientId.uuidString]).map(prescriptionLine(from:))
        }
        let pending = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM pending_card p JOIN ocr_card_commit c ON c.card_id = p.id
            WHERE c.patient_id = ? AND c.card_kind = ? AND \(scope.sql) AND p.status IN ('pending','in_progress')
            """, arguments: receiptArguments([patientId.uuidString, kind], scope)) ?? 0
        let active = try encounters.filter { id in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM encounter WHERE id = ? AND patient_id = ? AND deleted_at IS NULL", arguments: [id.uuidString, patientId.uuidString]) == 1
        }.sorted { $0.uuidString < $1.uuidString }
        return .init(kind: kind, entityId: entityId, patientId: patientId, fields: fields, sources: sources,
                     encounterIDs: active, relationshipEditable: kind != "encounter" && pending == 0, lines: lines)
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
    public func cards(documentId: UUID, patientId: UUID) async throws -> [(kind: String, id: UUID)] {
        try await writer.read { db in
            guard try String.fetchOne(db, sql: "SELECT patient_id FROM document_file WHERE id = ?", arguments: [documentId.uuidString]) == patientId.uuidString else { throw StoreError.invalidCard }
            var seen = Set<String>()
            var result: [(kind: String, id: UUID)] = []
            for row in try Row.fetchAll(db, sql: "SELECT * FROM ocr_card_commit WHERE document_file_id = ? AND patient_id = ? ORDER BY card_kind, entity_id",
                                        arguments: [documentId.uuidString, patientId.uuidString]) {
                let kind: String = row["card_kind"]
                guard let id = UUID(uuidString: try Self.headerId(of: row, db: db)), seen.insert("\(kind)/\(id.uuidString)").inserted else { continue }
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
                ) r ON r.id = e.id WHERE e.patient_id = ? AND e.deleted_at IS NULL ORDER BY e.date DESC
                """, arguments: [documentId.uuidString, patientId.uuidString, documentId.uuidString, patientId.uuidString,
                    documentId.uuidString, patientId.uuidString, documentId.uuidString, patientId.uuidString, patientId.uuidString])
                .compactMap(UUID.init(uuidString:))
        }
    }

    /// 改挂就诊：事实表 `encounter_id`（处方/票据/免疫）+ 该表头全部回执（表头回执 ∪ 行回执）的关系投影同事务更新。
    /// 两条 UPDATE 合计零行 → `invalidAssociation`（无回执又无 encounter_id 列的实体没有可改的关系，不伪装成功、不写审计）。
    public func associate(kind: String, entityId: UUID, patientId: UUID, encounterId: UUID?) async throws {
        guard Self.supportedKinds.contains(kind), kind != "encounter" else { throw StoreError.invalidCard }
        let table = Self.factTable(for: kind)
        try await writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id = ? AND patient_id = ?",
                                            arguments: [entityId.uuidString, patientId.uuidString]) else { throw StoreError.invalidCard }
            if ["prescription", "claim_item", "immunization"].contains(kind), (row["confirmed"] as Int?) != 1 { throw StoreError.invalidCard }
            if let encounterId {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM encounter WHERE id = ? AND patient_id = ? AND deleted_at IS NULL",
                                       arguments: [encounterId.uuidString, patientId.uuidString]) == 1 else { throw StoreError.invalidAssociation }
            }
            let scope = Self.receiptScope(kind: kind, headerId: entityId.uuidString, patientId: patientId.uuidString)
            let pending = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM pending_card p JOIN ocr_card_commit c ON c.card_id = p.id
                WHERE c.patient_id = ? AND c.card_kind = ? AND \(scope.sql) AND p.status IN ('pending','in_progress')
                """, arguments: Self.receiptArguments([patientId.uuidString, kind], scope)) ?? 0
            guard pending == 0 else { throw StoreError.committedDataChanged }
            var changed = 0
            if ["prescription", "claim_item", "immunization"].contains(kind) {
                try db.execute(sql: "UPDATE \(table) SET encounter_id = ?, updated_at = ? WHERE id = ? AND patient_id = ?",
                               arguments: [encounterId?.uuidString, Date().timeIntervalSince1970, entityId.uuidString, patientId.uuidString])
                changed += db.changesCount
            }
            try db.execute(sql: "UPDATE ocr_card_commit SET encounter_id = ? WHERE patient_id = ? AND card_kind = ? AND \(scope.sql)",
                           arguments: Self.receiptArguments([encounterId?.uuidString, patientId.uuidString, kind], scope))
            changed += db.changesCount
            guard changed >= 1 else { throw StoreError.invalidAssociation }
            let meta = String(decoding: try JSONEncoder().encode(["relationship": "encounter", "linked": encounterId == nil ? "false" : "true"]), as: UTF8.self)
            try AuditLogWriter.insert(action: "update", entityType: kind, entityId: entityId.uuidString, actorLocal: "owner", meta: meta, db: db)
        }
    }
}
#endif
