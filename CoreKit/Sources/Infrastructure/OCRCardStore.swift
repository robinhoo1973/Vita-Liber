#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

/// FR6.9 / BR-001 / BR-003: the only atomic OCR card confirmation boundary.
public actor OCRCardStore {
    public static let supportedKinds: Set<String> = ["metric_sample", "encounter", "prescription", "claim_item", "medication", "immunization"]
    static let auditEngine = "ocr-card-v22"
    let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    // MARK: - v25 卡类 → 事实表（子项目 D §C.13 / D1-3）

    /// 表头表 = `CardKindRegistry.entry(for:).headerTable`（回执 `entity_table` 默认值、detail/associate 的事实表）。
    /// 未注册卡类退回卡类名——`supportedKinds`/`validateReceipt` 仍会拒收，不会拼出不存在的表。
    public static func factTable(for kind: String) -> String {
        CardKindRegistry.entry(for: kind)?.headerTable ?? kind
    }

    /// 行表（处方行 / 费用行）；无行实体的卡类为 nil。
    static func lineTable(for kind: String) -> String? {
        CardKindRegistry.entry(for: kind)?.entityTables.dropFirst().first
    }

    /// 行表 → 父表 / 父键（DDL 事实，Infrastructure 持有；键与值均为静态字面量，可安全拼入 SQL）。
    static let lineParents: [String: (table: String, column: String)] = [
        "prescription_line": ("prescription", "prescription_id"),
        "claim_line": ("claim_item", "claim_item_id"),
    ]

    /// 回执定位谓词（SELECT / UPDATE 共用，列名不带别名）：
    /// 表头回执（entity_table = 表头表 ∧ entity_id = 表头 id）∪ 行回执（entity_table = 行表 ∧ entity_id ∈ 该表头同成员行 id）。
    /// v25 搬运的旧回执 entity_table = card_kind（表头），新处方/费用行回执指行——两代回执同一谓词到达同一表头。
    struct ReceiptScope {
        let sql: String
        let arguments: [DatabaseValueConvertible?]
    }

    static func receiptScope(kind: String, headerId: String, patientId: String) -> ReceiptScope {
        var sql = "(entity_table = ? AND entity_id = ?)"
        var arguments: [DatabaseValueConvertible?] = [factTable(for: kind), headerId]
        if let line = lineTable(for: kind), let parent = lineParents[line] {
            sql += " OR (entity_table = ? AND entity_id IN (SELECT id FROM \(line) WHERE \(parent.column) = ? AND patient_id = ?))"
            arguments += [line, headerId, patientId]
        }
        return ReceiptScope(sql: "(\(sql))", arguments: arguments)
    }

    static func receiptArguments(_ head: [DatabaseValueConvertible?], _ scope: ReceiptScope) -> StatementArguments {
        StatementArguments(head + scope.arguments)
    }

    /// 回执所指表头 id：表头回执直接取 entity_id；行回执经行表父键回到表头（行须与回执同成员，否则回执损坏）。
    static func headerId(of receipt: Row, db: Database) throws -> String {
        let table: String = receipt["entity_table"], entity: String = receipt["entity_id"], patient: String = receipt["patient_id"]
        guard let parent = lineParents[table] else { return entity }
        guard let header = try String.fetchOne(db, sql: "SELECT \(parent.column) FROM \(table) WHERE id = ? AND patient_id = ?",
                                               arguments: [entity, patient]) else { throw StoreError.corruptReceipt }
        return header
    }

    /// 卡的既有表头（≤ 1）：同一张卡的全部回执（表头回执或行回执）必须回到同一表头，否则回执损坏。
    static func existingHeader(receipts: [Row], db: Database) throws -> String? {
        var headers = Set<String>()
        for receipt in receipts { headers.insert(try headerId(of: receipt, db: db)) }
        guard headers.count <= 1 else { throw StoreError.corruptReceipt }
        return headers.first
    }

    public struct SaveResult: Sendable {
        public let remainingCard: MatchedCard?
        /// Newly committed source rows, not the number of SQL statements or prescription headers.
        public let writtenCount: Int
        public let resolved: Bool
        public let pendingCardId: String
    }

    public enum StoreError: Error, Sendable {
        case invalidCard, pendingNotFound, pendingIdentityMismatch, pendingNotActive
        case committedDataChanged, corruptReceipt
        case invalidAssociation
    }

    public struct ReviewState: Sendable {
        public let card: MatchedCard
        public let remaining: MatchedCard?
        public let hasCommittedRows: Bool
    }

    /// Receipt membership, not validation errors, identifies rows that have actually been saved.
    public func remainingCard(for pending: PendingCard) async throws -> MatchedCard {
        guard let document = pending.sourceDocId else { throw StoreError.pendingIdentityMismatch }
        let candidate = try pending.matchedCard()
        let state = try await reviewState(card: candidate, patientId: pending.patientId, documentId: document)
        var remaining = state.card
        remaining.rows = state.remaining?.rows ?? []
        return remaining
    }

    /// Restore the latest draft or the canonical committed audit before the App stages a re-review.
    public func reviewState(card candidate: MatchedCard, patientId: UUID, documentId: UUID) async throws -> ReviewState {
        try await writer.read { db in
            try DocumentStore.validateSource(db, patientId: patientId, documentId: documentId, pageIndex: candidate.pageIndex)
            let pendingRows = try Row.fetchAll(db, sql: """
                SELECT * FROM pending_card WHERE patient_id = ? AND source_doc_id = ? AND source_page = ? AND card_kind = ? AND source_type = 'ocr'
                """, arguments: [patientId.uuidString, documentId.uuidString, candidate.pageIndex, candidate.kind])
            guard pendingRows.count <= 1 else { throw StoreError.pendingIdentityMismatch }
            let pending = try pendingRows.first.map(PendingCardStore.decode)
            var card = try pending?.matchedCard() ?? candidate
            guard card.id == candidate.id else { throw StoreError.pendingIdentityMismatch }
            let receipts = try Row.fetchAll(db, sql: """
                SELECT * FROM ocr_card_commit WHERE patient_id = ? AND document_file_id = ? AND page_index = ? AND card_kind = ?
                """, arguments: [patientId.uuidString, documentId.uuidString, candidate.pageIndex, candidate.kind])
            guard receipts.allSatisfy({ ($0["card_id"] as String) == card.id.uuidString }) else { throw StoreError.pendingIdentityMismatch }
            for receipt in receipts { try Self.validateReceipt(receipt, db: db) }
            let committed = Set(receipts.map { $0["row_id"] as String })
            if pending == nil, !committed.isEmpty {
                let audits = try Self.exportCommits(db).filter { $0.cardId == card.id }
                if let shared = audits.first?.shared { card.shared = shared }
                let byRow = Dictionary(uniqueKeysWithValues: audits.map { ($0.rowId, $0) })
                card.rows = card.rows.map { row in
                    byRow[row.id].map { MatchedCardRow(id: $0.rowId, fields: $0.fields) } ?? row
                }
                let represented = Set(card.rows.map(\.id))
                card.rows += audits.filter { !represented.contains($0.rowId) }.map { .init(id: $0.rowId, fields: $0.fields) }
            }
            var remaining = card
            remaining.rows.removeAll { committed.contains($0.id.uuidString) || EntityCardProjection.isDiscarded($0, in: card) }
            if let pending, ["resolved", "expired", "archived"].contains(pending.status) { remaining.rows = [] }
            return ReviewState(card: card, remaining: remaining.rows.isEmpty ? nil : remaining, hasCommittedRows: !committed.isEmpty)
        }
    }

    /// This is also the backup representation of a receipt. It contains only committed fields.
    public struct AuditRecord: Codable, Sendable, Equatable {
        public var cardId: UUID
        public var rowId: UUID
        public var patientId: UUID
        public var documentId: UUID
        public var pageIndex: Int
        public var cardKind: String
        public var entityId: UUID
        public var shared: [FieldDraft]
        public var fields: [FieldDraft]
        public var recordedAt: Date
        /// 当前关系投影随备份携带；机器识别原文仍在shared/fields，不因改挂而改变。
        public var encounterId: UUID? = nil
        /// v25（§C.0-6）：回执所指真实实体表（表头表或 `prescription_line`/`claim_line`）。
        /// Optional：旧回执 / 旧备份缺省 = `cardKind`（表头）；`insertReceipt` 写 `entity_table = entityTable ?? cardKind`。
        public var entityTable: String? = nil
    }

    /// 表头的来源页：表头回执 ∪ 其行回执（处方/费用的来源页经行回执到达）。
    public func sourceRefs(entityId: UUID, patientId: UUID, cardKind: String) async throws -> [String] {
        guard Self.supportedKinds.contains(cardKind) else { throw StoreError.invalidCard }
        return try await writer.read { db in
            let scope = Self.receiptScope(kind: cardKind, headerId: entityId.uuidString, patientId: patientId.uuidString)
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM ocr_card_commit WHERE patient_id = ? AND card_kind = ? AND \(scope.sql)
                ORDER BY document_file_id, page_index, row_id
                """, arguments: Self.receiptArguments([patientId.uuidString, cardKind], scope))
            var seen = Set<String>()
            return try rows.compactMap { row in
                try Self.validateReceipt(row, db: db)
                guard let document = UUID(uuidString: row["document_file_id"]) else { throw StoreError.corruptReceipt }
                let ref = HospitalSample.sourceRef(documentId: document, pageIndex: row["page_index"])
                return seen.insert(ref).inserted ? ref : nil
            }
        }
    }

    public func save(card: MatchedCard, patientId: UUID, documentId: UUID,
                     pendingCardId: String? = nil) async throws -> SaveResult {
        try await writer.write { db in
            guard Self.supportedKinds.contains(card.kind), !card.rows.isEmpty,
                  Set(card.rows.map(\.id)).count == card.rows.count,
                  card.kind != "encounter" || card.rows.count == 1 else { throw StoreError.invalidCard }
            try DocumentStore.validateSource(db, patientId: patientId, documentId: documentId, pageIndex: card.pageIndex)
            let now = Date()
            let matches = try Row.fetchAll(db, sql: """
                SELECT * FROM pending_card WHERE source_doc_id = ? AND source_page = ? AND card_kind = ?
                """, arguments: [documentId.uuidString, card.pageIndex, card.kind])
            guard matches.count <= 1 else { throw StoreError.pendingIdentityMismatch }
            var pending = try matches.first.map(PendingCardStore.decode)
            if let pendingCardId {
                guard let found = try Row.fetchOne(db, sql: "SELECT * FROM pending_card WHERE id = ?", arguments: [pendingCardId]) else {
                    throw StoreError.pendingNotFound
                }
                let requested = try PendingCardStore.decode(found)
                guard pending?.id == requested.id else { throw StoreError.pendingIdentityMismatch }
                pending = requested
            }
            if let pending {
                guard pending.patientId == patientId, pending.sourceDocId == documentId,
                      pending.sourcePage == card.pageIndex, pending.cardKind == card.kind, pending.sourceType == "ocr" else {
                    throw StoreError.pendingIdentityMismatch
                }
                guard ["pending", "in_progress", "resolved"].contains(pending.status), pending.note != "discarded" else {
                    throw StoreError.pendingNotActive
                }
            }
            let previous = try pending?.matchedCard()
            if let previous, previous.id != card.id { throw StoreError.pendingIdentityMismatch }
            let sourceCards = try String.fetchAll(db, sql: "SELECT DISTINCT card_id FROM ocr_card_commit WHERE document_file_id = ? AND page_index = ? AND card_kind = ?",
                                                  arguments: [documentId.uuidString, card.pageIndex, card.kind])
            guard sourceCards.isEmpty || sourceCards.contains(card.id.uuidString) else { throw StoreError.pendingIdentityMismatch }
            let receipts = try Row.fetchAll(db, sql: "SELECT * FROM ocr_card_commit WHERE card_id = ?", arguments: [card.id.uuidString])
            for receipt in receipts {
                guard (receipt["patient_id"] as String) == patientId.uuidString,
                      (receipt["document_file_id"] as String) == documentId.uuidString,
                      (receipt["page_index"] as Int) == card.pageIndex,
                      (receipt["card_kind"] as String) == card.kind else { throw StoreError.pendingIdentityMismatch }
                try Self.validateReceipt(receipt, db: db)
            }
            let committed = Set(receipts.map { $0["row_id"] as String })
            var snapshot = card
            if let previous, !committed.isEmpty {
                snapshot = try Self.mergeDraft(card, previous: previous, committed: committed)
            } else if previous == nil, !committed.isEmpty {
                // Restored receipts have no D-grade pending snapshot. Replays must still agree with the committed audit.
                let audits = try Self.exportCommits(db).filter { $0.cardId == card.id }
                guard let first = audits.first, first.shared == card.shared.filter(\.isConfirmed) else { throw StoreError.committedDataChanged }
                for row in card.rows where committed.contains(row.id.uuidString) {
                    guard EntityCardProjection.invalidFields(in: card, row: row, calendar: Calendar(identifier: .gregorian)).isEmpty,
                          audits.first(where: { $0.rowId == row.id })?.fields == row.fields.filter({ $0.isConfirmed && $0.key != "metric_key" }) else {
                        throw StoreError.committedDataChanged
                    }
                }
                let supplied = Set(card.rows.map(\.id))
                snapshot.rows = audits.filter { !supplied.contains($0.rowId) }.map { MatchedCardRow(id: $0.rowId, fields: $0.fields) } + card.rows
            }
            if let pending, pending.status == "resolved" {
                guard let previous, previous.shared == snapshot.shared,
                      previous.rows.map(\.id) == snapshot.rows.map(\.id),
                      zip(previous.rows, snapshot.rows).allSatisfy({ pair in pair.0.fields == pair.1.fields }) else {
                    throw StoreError.committedDataChanged
                }
                return SaveResult(remainingCard: nil, writtenCount: 0, resolved: true, pendingCardId: pending.id)
            }

            let id: String
            if let pending { id = pending.id }
            else {
                let raw = try String.fetchOne(db, sql: "SELECT ocr_text FROM document_page WHERE document_file_id = ? AND page_index = ?",
                                              arguments: [documentId.uuidString, card.pageIndex]) ?? ""
                id = try PendingCardStore.upsert(PendingCardDraft(patientId: patientId, sourceType: "ocr", sourceDocId: documentId,
                    sourcePage: card.pageIndex, cardKind: card.kind, incompleteFields: [], partialData: PendingCardPayload(card: snapshot), rawText: raw),
                    db: db, now: now)
            }
            var residual: [MatchedCardRow] = []
            var accepted: [MatchedCardRow] = []
            var incomplete: [IncompleteField] = []
            for row in snapshot.rows where !committed.contains(row.id.uuidString) {
                if EntityCardProjection.isDiscarded(row, in: snapshot) { continue }
                let invalid = EntityCardProjection.invalidFields(in: snapshot, row: row, calendar: Calendar(identifier: .gregorian))
                if invalid.isEmpty { var valid = row; valid.missingRequired = []; accepted.append(valid) }
                else {
                    var remaining = row; remaining.missingRequired = invalid
                    residual.append(remaining)
                    incomplete += invalid.map { IncompleteField(key: $0, reason: "requires_review", rowId: row.id) }
                }
            }
            var projectionCard = snapshot
            projectionCard.rows = accepted
            var entities: [UUID: UUID] = [:]
            /// 行 → 回执 entity_table（缺省 = 表头表；处方/费用行回执指行表）。
            var tables: [UUID: String] = [:]
            var associatedEncounter = accepted.isEmpty ? nil : try Self.validateAssociation(snapshot, patientId: patientId, db: db)
            let calendar = Calendar(identifier: .gregorian)
            switch card.kind {
            case "metric_sample":
                let projection = EntityCardProjection.hospitalSamples(from: projectionCard, calendar: Calendar(identifier: .gregorian))
                guard projection.samples.count == accepted.count else { throw StoreError.invalidCard }
                for (row, sample) in zip(accepted, projection.samples) {
                    let entity = UUID()
                    let codingSystem = row.fields.first { $0.key == "raw_label" }?.codeApproval?.resolution.codingSystem
                    try TrendQueryStore.insertHospitalSample(sample, id: entity, patientId: patientId,
                        sourceRef: HospitalSample.sourceRef(documentId: documentId, pageIndex: card.pageIndex), db: db, now: now,
                        approvedCodingSystem: codingSystem)
                    entities[row.id] = entity
                }
            case "encounter":
                if let row = accepted.first {
                    guard let encounter = EntityCardProjection.encounterDraft(from: projectionCard, patientId: patientId,
                                                                              calendar: Calendar(identifier: .gregorian)) else { throw StoreError.invalidCard }
                    if let existing = associatedEncounter {
                        // 多份原件为同一次就诊补空字段；冲突值保留在独立来源卡中，不覆盖已有诊断/叙事。
                        // v25 五叙事列（§C.1）同一补空纪律：原文保存、不摘要不改写。
                        try db.execute(sql: """
                            UPDATE encounter SET hospital = COALESCE(NULLIF(hospital, ''), ?),
                              department = COALESCE(NULLIF(department, ''), ?), doctor = COALESCE(NULLIF(doctor, ''), ?),
                              chief_complaint = COALESCE(NULLIF(chief_complaint, ''), ?),
                              diagnosis_text = COALESCE(NULLIF(diagnosis_text, ''), ?), advice_text = COALESCE(NULLIF(advice_text, ''), ?),
                              present_illness = COALESCE(NULLIF(present_illness, ''), ?), visit_summary = COALESCE(NULLIF(visit_summary, ''), ?),
                              past_history = COALESCE(NULLIF(past_history, ''), ?), physical_exam = COALESCE(NULLIF(physical_exam, ''), ?),
                              allergy_history = COALESCE(NULLIF(allergy_history, ''), ?), updated_at = ?
                            WHERE id = ? AND patient_id = ? AND deleted_at IS NULL
                            """, arguments: [encounter.hospital, encounter.department, encounter.doctor,
                                encounter.chiefComplaint, encounter.diagnosisText, encounter.adviceText,
                                encounter.presentIllness, encounter.visitSummary, encounter.pastHistory,
                                encounter.physicalExam, encounter.allergyHistory,
                                now.timeIntervalSince1970, existing.uuidString, patientId.uuidString])
                        guard db.changesCount == 1 else { throw StoreError.invalidAssociation }
                        entities[row.id] = existing
                    } else {
                        try db.execute(sql: """
                        INSERT INTO encounter (id, patient_id, date, kind, hospital, department, doctor,
                          chief_complaint, diagnosis_text, advice_text, created_at, updated_at,
                          present_illness, visit_summary, past_history, physical_exam, allergy_history)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [encounter.id.uuidString, patientId.uuidString, encounter.date.timeIntervalSince1970,
                            encounter.kind, encounter.hospital, encounter.department, encounter.doctor, encounter.chiefComplaint,
                            encounter.diagnosisText, encounter.adviceText, now.timeIntervalSince1970, now.timeIntervalSince1970,
                            encounter.presentIllness, encounter.visitSummary, encounter.pastHistory,
                            encounter.physicalExam, encounter.allergyHistory])
                        entities[row.id] = encounter.id
                        associatedEncounter = encounter.id
                    }
                }
            case "prescription":
                if !accepted.isEmpty {
                    // v25（§C.6）：表头 + 逐行 prescription_line；行意图与 accepted 行一一对应（rowId 同序）。
                    guard let intent = EntityCardProjection.prescriptionIntent(from: projectionCard),
                          intent.lines.map(\.rowId) == accepted.map(\.id) else { throw StoreError.invalidCard }
                    // 卡片互联（FR6.9 期二）：处方归属就诊卡——按确认卡
                    // EncounterAssociation 显式选择归属（证据化建议由
                    // EncounterResolver 生成；无信号不猜、encounter_id 保持
                    // NULL，绝不张冠李戴）
                    let encounterId = associatedEncounter
                    let entity: UUID
                    if let existing = try Self.existingHeader(receipts: receipts, db: db) {
                        guard let uuid = UUID(uuidString: existing) else { throw StoreError.corruptReceipt }
                        entity = uuid
                        // 已提交部分的表头列 + 行事实列必须仍与回执一致（不比 advice_text：v24 折叠串原样保留，
                        // v25 回填行才是事实；BR-003 不从拼串猜回）。
                        var committedCard = snapshot
                        committedCard.rows = snapshot.rows.filter { committed.contains($0.id.uuidString) }
                        guard let prior = EntityCardProjection.prescriptionIntent(from: committedCard),
                              let stored = try Row.fetchOne(db, sql: "SELECT * FROM prescription WHERE id = ? AND patient_id = ?",
                                                            arguments: [existing, patientId.uuidString]),
                              Self.prescriptionHeaderMatches(stored, prior),
                              try Self.prescriptionLinesMatch(prior, header: existing, patientId: patientId.uuidString, db: db) else {
                            throw StoreError.committedDataChanged
                        }
                        // 表头只补空（多页/后补行不覆盖既有列；共享面在 mergeDraft 已保证不变）。
                        try db.execute(sql: """
                            UPDATE prescription SET advice_text = COALESCE(NULLIF(advice_text, ''), ?),
                              department = COALESCE(NULLIF(department, ''), ?), prescription_no = COALESCE(NULLIF(prescription_no, ''), ?),
                              prescription_type = COALESCE(NULLIF(prescription_type, ''), ?), fee_type_text = COALESCE(NULLIF(fee_type_text, ''), ?),
                              clinical_diagnosis = COALESCE(NULLIF(clinical_diagnosis, ''), ?), pharmacist_names = COALESCE(NULLIF(pharmacist_names, ''), ?),
                              total_amount = COALESCE(total_amount, ?), encounter_id = COALESCE(encounter_id, ?), updated_at = ?
                            WHERE id = ? AND patient_id = ?
                            """, arguments: [Self.normalized(intent.adviceText), intent.department, intent.prescriptionNo,
                                             intent.prescriptionType, intent.feeTypeText, intent.clinicalDiagnosis, intent.pharmacistNames,
                                             intent.totalAmount, encounterId?.uuidString,
                                             now.timeIntervalSince1970, existing, patientId.uuidString])
                        guard db.changesCount == 1 else { throw StoreError.committedDataChanged }
                    } else {
                        entity = UUID()
                        try db.execute(sql: """
                            INSERT INTO prescription (id, patient_id, encounter_id, document_file_id, source,
                              hospital, doctor, prescribed_at, advice_text, confirmed, created_at, updated_at,
                              department, prescription_no, prescription_type, fee_type_text, clinical_diagnosis, pharmacist_names, total_amount)
                            VALUES (?, ?, ?, ?, 'ocr', ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [entity.uuidString, patientId.uuidString, encounterId?.uuidString,
                                documentId.uuidString, intent.hospital,
                                intent.doctor, intent.prescribedAt.timeIntervalSince1970, Self.normalized(intent.adviceText),
                                now.timeIntervalSince1970, now.timeIntervalSince1970,
                                intent.department, intent.prescriptionNo, intent.prescriptionType, intent.feeTypeText,
                                intent.clinicalDiagnosis, intent.pharmacistNames, intent.totalAmount])
                    }
                    for (row, item) in zip(accepted, intent.lines) {
                        var line = item.line
                        line.prescriptionId = entity; line.patientId = patientId
                        line.confirmed = true; line.createdAt = now; line.updatedAt = now
                        line.ordinal = try Self.freeOrdinal(table: "prescription_line", parentColumn: "prescription_id", header: entity.uuidString,
                                                            preferred: snapshot.rows.firstIndex { $0.id == row.id }, db: db)
                        try Self.insertPrescriptionLine(line, db: db)
                        entities[row.id] = line.id
                        tables[row.id] = "prescription_line"
                    }
                }
            case "claim_item":
                if !accepted.isEmpty {
                    // v25（§C.7）：票据表头 + 费用明细行；无 item_name 的空行 = 表头即实体（票据页），沿表头回执路径。
                    guard let intent = EntityCardProjection.claimIntent(from: projectionCard, calendar: calendar) else { throw StoreError.invalidCard }
                    let entity: UUID
                    if let existing = try Self.existingHeader(receipts: receipts, db: db) {
                        guard let uuid = UUID(uuidString: existing) else { throw StoreError.corruptReceipt }
                        entity = uuid
                        var committedCard = snapshot
                        committedCard.rows = snapshot.rows.filter { committed.contains($0.id.uuidString) }
                        guard let prior = EntityCardProjection.claimIntent(from: committedCard, calendar: calendar),
                              let stored = try Row.fetchOne(db, sql: "SELECT * FROM claim_item WHERE id = ? AND patient_id = ?",
                                                            arguments: [existing, patientId.uuidString]),
                              Self.claimHeaderMatches(stored, prior),
                              try Self.claimLinesMatch(prior, header: existing, patientId: patientId.uuidString, db: db) else {
                            throw StoreError.committedDataChanged
                        }
                        try db.execute(sql: """
                            UPDATE claim_item SET merchant = COALESCE(NULLIF(merchant, ''), ?), summary = COALESCE(NULLIF(summary, ''), ?),
                              invoice_no = COALESCE(NULLIF(invoice_no, ''), ?), insurance_type_text = COALESCE(NULLIF(insurance_type_text, ''), ?),
                              reimbursed_amount = COALESCE(reimbursed_amount, ?), out_of_pocket = COALESCE(out_of_pocket, ?),
                              personal_account_amount = COALESCE(personal_account_amount, ?),
                              encounter_id = COALESCE(encounter_id, ?), updated_at = ?
                            WHERE id = ? AND patient_id = ?
                            """, arguments: [intent.merchant, intent.summary, intent.invoiceNo, intent.insuranceTypeText,
                                             intent.reimbursedAmount, intent.outOfPocket, intent.personalAccountAmount,
                                             associatedEncounter?.uuidString, now.timeIntervalSince1970, existing, patientId.uuidString])
                        guard db.changesCount == 1 else { throw StoreError.committedDataChanged }
                    } else {
                        entity = UUID()
                        try db.execute(sql: """
                            INSERT INTO claim_item (id, patient_id, encounter_id, document_file_id, item_type, amount, currency, date, merchant, summary,
                              confirmed, created_at, updated_at, reimbursed_amount, out_of_pocket, personal_account_amount, invoice_no, insurance_type_text)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [entity.uuidString, patientId.uuidString, associatedEncounter?.uuidString, documentId.uuidString,
                                intent.itemType, intent.amount, intent.currency, intent.date.timeIntervalSince1970, intent.merchant, intent.summary,
                                now.timeIntervalSince1970, now.timeIntervalSince1970,
                                intent.reimbursedAmount, intent.outOfPocket, intent.personalAccountAmount, intent.invoiceNo, intent.insuranceTypeText])
                    }
                    let linesByRow = Dictionary(uniqueKeysWithValues: intent.lines.map { ($0.rowId, $0) })
                    for row in accepted {
                        guard let item = linesByRow[row.id] else { entities[row.id] = entity; continue }
                        let ordinal = try Self.freeOrdinal(table: "claim_line", parentColumn: "claim_item_id", header: entity.uuidString,
                                                           preferred: snapshot.rows.firstIndex { $0.id == row.id }, db: db)
                        try Self.insertClaimLine(item, header: entity, patientId: patientId, ordinal: ordinal, page: card.pageIndex, now: now, db: db)
                        entities[row.id] = item.rowId
                        tables[row.id] = "claim_line"
                    }
                }
            case "medication":
                for row in accepted {
                    let values = EntityCardProjection.confirmedValues(row.fields)
                    guard let name = values["generic_name"], let unit = values["unit_kind"] else { throw StoreError.invalidCard }
                    let entity = UUID()
                    try db.execute(sql: """
                        INSERT INTO medication (id, patient_id, generic_name, brand_name, spec, unit_kind, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [entity.uuidString, patientId.uuidString, name, values["brand_name"], values["spec"], unit, now.timeIntervalSince1970, now.timeIntervalSince1970])
                    entities[row.id] = entity
                }
            case "immunization":
                if let row = accepted.first {
                    let values = EntityCardProjection.confirmedValues(snapshot.shared)
                    guard let name = values["vaccine_name"], let dose = values["dose_number"].flatMap(Int.init),
                          let date = values["administered_at"].flatMap({ EntityCardProjection.parseDate($0, calendar: .current) }) else { throw StoreError.invalidCard }
                    let entity = UUID()
                    try db.execute(sql: """
                        INSERT INTO immunization (id, patient_id, vaccine_name, dose_number, administered_at, provider, lot_number, encounter_id, source, confirmed, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'ocr', 1, ?, ?)
                        """, arguments: [entity.uuidString, patientId.uuidString, name, dose, date.timeIntervalSince1970,
                            values["provider"], values["lot_number"], associatedEncounter?.uuidString, now.timeIntervalSince1970, now.timeIntervalSince1970])
                    entities[row.id] = entity
                }
            default: throw StoreError.invalidCard
            }
            let headerTable = Self.factTable(for: card.kind)
            for row in accepted {
                guard let entity = entities[row.id] else { throw StoreError.invalidCard }
                let audit = AuditRecord(cardId: card.id, rowId: row.id, patientId: patientId, documentId: documentId,
                    pageIndex: card.pageIndex, cardKind: card.kind, entityId: entity,
                    shared: snapshot.shared.filter(\.isConfirmed),
                    fields: row.fields.filter { $0.isConfirmed && $0.key != "metric_key" }, recordedAt: now, encounterId: associatedEncounter,
                    entityTable: tables[row.id] ?? headerTable)
                try Self.insertReceipt(audit, db: db)
            }
            let residualById = Dictionary(uniqueKeysWithValues: residual.map { ($0.id, $0) })
            let acceptedById = Dictionary(uniqueKeysWithValues: accepted.map { ($0.id, $0) })
            snapshot.rows = snapshot.rows.map { residualById[$0.id] ?? acceptedById[$0.id] ?? $0 }
            let resolved = residual.isEmpty
            let json = try PendingCardPayload(card: snapshot).json
            let incompleteJSON = String(decoding: try JSONEncoder().encode(incomplete), as: UTF8.self)
            try db.execute(sql: """
                UPDATE pending_card SET partial_data = ?, incomplete_fields = ?, status = ?, updated_at = ?,
                  attempt_count = attempt_count + 1, resolved_at = ?, resolved_by = ?, note = NULL
                WHERE id = ? AND status IN ('pending','in_progress')
                """, arguments: [json, incompleteJSON, resolved ? "resolved" : "in_progress", now.timeIntervalSince1970,
                    resolved ? now.timeIntervalSince1970 : nil, resolved ? "user" : nil, id])
            guard db.changesCount == 1 else { throw StoreError.pendingNotActive }
            try Self.refreshDocumentProjection(documentId: documentId, patientId: patientId, db: db, now: now)
            var remaining = snapshot; remaining.rows = residual
            return SaveResult(remainingCard: resolved ? nil : remaining, writtenCount: accepted.count, resolved: resolved, pendingCardId: id)
        }
    }

    public func encounterCandidates(patientId: UUID) async throws -> [EncounterResolver.Candidate] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, date, hospital, doctor FROM encounter WHERE patient_id = ? AND deleted_at IS NULL ORDER BY date DESC LIMIT 500",
                             arguments: [patientId.uuidString]).compactMap { row in
                guard let id = UUID(uuidString: row["id"] as String) else { return nil }
                return .init(id: id, patientId: patientId, date: Date(timeIntervalSince1970: row["date"]), hospital: row["hospital"], doctor: row["doctor"])
            }
        }
    }

    private static func validateAssociation(_ card: MatchedCard, patientId: UUID, db: Database) throws -> UUID? {
        if case .suggested(_, let evidence) = card.encounterAssociation,
           evidence != EncounterResolver.evidenceKey(for: card) { throw StoreError.invalidAssociation }
        guard let id = card.encounterAssociation.encounterID else { return nil }
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM encounter WHERE id = ? AND patient_id = ? AND deleted_at IS NULL",
                               arguments: [id.uuidString, patientId.uuidString]) == 1 else { throw StoreError.invalidAssociation }
        return id
    }

    static func refreshDocumentProjection(documentId: UUID, patientId: UUID, db: Database, now: Date) throws {
        let jsons = try String.fetchAll(db, sql: "SELECT raw_blocks FROM ocr_result WHERE document_file_id = ? AND engine_version = ? ORDER BY page_index, created_at",
                                       arguments: [documentId.uuidString, auditEngine])
        // H4 审查修复：JSONDecoder 每行新建（P×C 个实例、每次全量重建类型元数据）——
        // 提升为单实例复用。逐行解码本身是投影任务的固有成本（完整投影必须
        // 覆盖全部页面的已确认字段），页数×卡数有界（文档 ≤ 数十页），不再重排。
        let decoder = JSONDecoder()
        let audits = try jsons.map { try decoder.decode(AuditRecord.self, from: Data($0.utf8)) }
        guard !audits.isEmpty else { return }
        // CI 34653854625 修复：单链长表达式超出 macOS Swift 6 类型检查预算
        // （Linux 6.3.1 类型检查通过、macOS 超时——该表达式正处在预算边界）。
        // 拆子表达式：确认字段集合 → 值/单位行文本 → 全文。
        let confirmedFields = audits.flatMap { $0.shared + $0.fields }
            .filter(\.isConfirmed)
            .filter { $0.key != "metric_key" }
        let text = confirmedFields
            .map { field in [field.value, field.unit].compactMap { $0 }.joined(separator: " ") }
            .joined(separator: "\n")
        let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_card WHERE source_doc_id = ? AND status IN ('pending','in_progress')",
                                      arguments: [documentId.uuidString]) ?? 0
        // FR6.9 智能文档命名：若文档标题为空，依据已确认字段自动设置标准化标题
        let currentTitle = try String.fetchOne(db, sql: "SELECT title FROM document_file WHERE id = ? AND patient_id = ?",
                                               arguments: [documentId.uuidString, patientId.uuidString])
        var titleUpdateSQL = ""
        var arguments: [DatabaseValueConvertible] = [text, pending == 0 ? "C" : "D", now.timeIntervalSince1970]
        if currentTitle == nil || currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
           let suggested = DocumentNaming.suggestTitle(fields: confirmedFields, documentType: audits.first?.cardKind) {
            titleUpdateSQL = ", title = ?"
            arguments.append(suggested)
        }
        arguments.append(contentsOf: [documentId.uuidString, patientId.uuidString])
        // FTS触发器只看到已确认投影；原始OCR页文本/拒绝字段不加入搜索。
        try db.execute(sql: "UPDATE document_file SET ocr_text = ?, grade = ?, updated_at = ?\(titleUpdateSQL) WHERE id = ? AND patient_id = ?",
                       arguments: StatementArguments(arguments))
    }

    static func mergeDraft(_ incoming: MatchedCard, previous: MatchedCard, committed: Set<String>) throws -> MatchedCard {
        guard incoming.id == previous.id, incoming.kind == previous.kind, incoming.pageIndex == previous.pageIndex,
              Set(incoming.rows.map(\.id)).count == incoming.rows.count else { throw StoreError.pendingIdentityMismatch }
        guard committed.isEmpty || previous.shared == incoming.shared else { throw StoreError.committedDataChanged }
        guard committed.isEmpty || previous.encounterAssociation == incoming.encounterAssociation else { throw StoreError.committedDataChanged }
        for row in incoming.rows where committed.contains(row.id.uuidString) {
            guard previous.rows.first(where: { $0.id == row.id })?.fields == row.fields else { throw StoreError.committedDataChanged }
        }
        let rows = Dictionary(uniqueKeysWithValues: incoming.rows.map { ($0.id, $0) })
        let oldIds = Set(previous.rows.map(\.id))
        var result = incoming
        result.rows = previous.rows.map { old in committed.contains(old.id.uuidString) ? old : (rows[old.id] ?? old) }
            + incoming.rows.filter { !oldIds.contains($0.id) }
        return result
    }

    /// 回执 = `ocr_card_commit` 行 + `ocr_result` 审计 JSON（同事务）。`entity_table = entityTable ?? cardKind`（旧备份缺省表头），
    /// 且必须是该卡类注册的事实表之一（CHECK 枚举之外由 DDL 拒收，卡类/表错配在此拒收）。
    static func insertReceipt(_ audit: AuditRecord, db: Database) throws {
        let table = audit.entityTable ?? audit.cardKind
        guard CardKindRegistry.entry(for: audit.cardKind)?.entityTables.contains(table) == true else { throw StoreError.invalidCard }
        try db.execute(sql: """
            INSERT INTO ocr_card_commit (card_id, row_id, patient_id, document_file_id, page_index, card_kind, entity_table, entity_id, encounter_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [audit.cardId.uuidString, audit.rowId.uuidString, audit.patientId.uuidString,
                audit.documentId.uuidString, audit.pageIndex, audit.cardKind, table, audit.entityId.uuidString,
                audit.encounterId?.uuidString, audit.recordedAt.timeIntervalSince1970])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(audit), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO ocr_result (id, document_file_id, page_index, raw_blocks, engine_version, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [UUID().uuidString, audit.documentId.uuidString, audit.pageIndex, json, auditEngine, audit.recordedAt.timeIntervalSince1970])
    }

    /// 回执完整性：来源页存在且属于该成员；`entity_table` 是该卡类注册的事实表；实体存在、同成员。
    /// 行回执（prescription_line / claim_line）经父表校验 `document_file_id == 来源文档 ∧ confirmed = 1`（处方行自身亦须 confirmed）。
    static func validateReceipt(_ row: Row, db: Database) throws {
        let kind: String = row["card_kind"], table: String = row["entity_table"]
        let patient: String = row["patient_id"], document: String = row["document_file_id"]
        let page: Int = row["page_index"], entity: String = row["entity_id"]
        guard supportedKinds.contains(kind), page >= 0,
              CardKindRegistry.entry(for: kind)?.entityTables.contains(table) == true,
              try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM document_file d JOIN document_page p ON p.document_file_id = d.id
                WHERE d.id = ? AND d.patient_id = ? AND p.page_index = ? AND p.status = 'ok'
                """, arguments: [document, patient, page]) == 1 else {
            throw StoreError.corruptReceipt
        }
        if let parent = lineParents[table] {
            guard let line = try Row.fetchOne(db, sql: """
                SELECT h.document_file_id AS header_document, h.confirmed AS header_confirmed, l.*
                FROM \(table) l JOIN \(parent.table) h ON h.id = l.\(parent.column) AND h.patient_id = l.patient_id
                WHERE l.id = ? AND l.patient_id = ?
                """, arguments: [entity, patient]),
                  (line["header_document"] as String?) == document, (line["header_confirmed"] as Int) == 1 else { throw StoreError.corruptReceipt }
            if line.hasColumn("confirmed"), (line["confirmed"] as Int) != 1 { throw StoreError.corruptReceipt }
        } else {
            guard let fact = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id = ? AND patient_id = ?", arguments: [entity, patient]) else {
                throw StoreError.corruptReceipt
            }
            if table == "metric_sample" {
                guard (fact["source_ref"] as String?) == "doc:\(document)#p\(page)", (fact["origin"] as String) == "hospital" else { throw StoreError.corruptReceipt }
            } else if table == "prescription" || table == "claim_item" {
                guard (fact["document_file_id"] as String?) == document, (fact["confirmed"] as Int) == 1 else { throw StoreError.corruptReceipt }
            }
            if table == "immunization", (fact["confirmed"] as Int) != 1 { throw StoreError.corruptReceipt }
        }
        if let encounter: String = row["encounter_id"] {
            guard try String.fetchOne(db, sql: "SELECT patient_id FROM encounter WHERE id = ?", arguments: [encounter]) == patient else { throw StoreError.corruptReceipt }
        }
    }

    // MARK: - v25 处方行 / 费用行（§C.6 / §C.7）

    /// 文本列比对口径：trim 后空串视同 NULL（v25 回填与新写入的单位/备注空值形态统一）。
    static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// 行序：优先卡内原始行序（后补行落回原位，保持处方/清单打印顺序）；该 ordinal 已被占用
    /// （如 v25 回填行按回执序编号）则退回 MAX(ordinal)+1——UNIQUE(parent, ordinal) 不撞车、不重排既有行。
    static func freeOrdinal(table: String, parentColumn: String, header: String, preferred: Int?, db: Database) throws -> Int {
        if let preferred,
           try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(parentColumn) = ? AND ordinal = ?", arguments: [header, preferred]) == 0 {
            return preferred
        }
        return try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(ordinal) + 1, 0) FROM \(table) WHERE \(parentColumn) = ?", arguments: [header]) ?? 0
    }

    /// `prescription_line` 全列 INSERT（DDL 同名同序；BR-006/007 剂量/数量原文 + 单位）。
    static func insertPrescriptionLine(_ line: PrescriptionLine, db: Database) throws {
        guard line.prescriptionId != PrescriptionLine.unassignedId, line.patientId != PrescriptionLine.unassignedId else { throw StoreError.invalidCard }
        try db.execute(sql: """
            INSERT INTO prescription_line (id, prescription_id, patient_id, ordinal, printed_name, generic_name, brand_name, drug_form, spec,
              dose_text, dose_unit, quantity_text, quantity_unit, frequency_text, route_text, duration_text, start_date, end_date, as_needed_text,
              medication_notes, note, raw_text, insurance_code, item_code_text, unit_price, amount, medication_id, source_page, source_row_id,
              confirmed, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [line.id.uuidString, line.prescriptionId.uuidString, line.patientId.uuidString, line.ordinal, line.printedName,
                line.genericName, line.brandName, line.drugForm, line.spec,
                line.doseText, line.doseUnit, line.quantityText, line.quantityUnit, line.frequencyText, line.routeText, line.durationText,
                line.startDate?.timeIntervalSince1970, line.endDate?.timeIntervalSince1970, line.asNeededText,
                line.medicationNotes, line.note, line.rawText, line.insuranceCode, line.itemCodeText, line.unitPrice, line.amount,
                line.medicationId?.uuidString, line.sourcePage, line.sourceRowId?.uuidString,
                line.confirmed ? 1 : 0, line.createdAt.timeIntervalSince1970, line.updatedAt.timeIntervalSince1970])
    }

    /// `prescription_line` 行 → Domain 实体（读面共用：detail.lines / lineDetail / 再确认比对）。
    static func prescriptionLine(from row: Row) throws -> PrescriptionLine {
        guard let id = UUID(uuidString: row["id"]), let prescription = UUID(uuidString: row["prescription_id"]),
              let patient = UUID(uuidString: row["patient_id"]) else { throw StoreError.corruptReceipt }
        return PrescriptionLine(
            id: id, prescriptionId: prescription, patientId: patient, ordinal: row["ordinal"], printedName: row["printed_name"],
            genericName: row["generic_name"], brandName: row["brand_name"], drugForm: row["drug_form"], spec: row["spec"],
            doseText: row["dose_text"], doseUnit: row["dose_unit"], quantityText: row["quantity_text"], quantityUnit: row["quantity_unit"],
            frequencyText: row["frequency_text"], routeText: row["route_text"], durationText: row["duration_text"],
            startDate: (row["start_date"] as Double?).map(Date.init(timeIntervalSince1970:)),
            endDate: (row["end_date"] as Double?).map(Date.init(timeIntervalSince1970:)),
            asNeededText: row["as_needed_text"], medicationNotes: row["medication_notes"], note: row["note"], rawText: row["raw_text"],
            insuranceCode: row["insurance_code"], itemCodeText: row["item_code_text"], unitPrice: row["unit_price"], amount: row["amount"],
            medicationId: (row["medication_id"] as String?).flatMap(UUID.init(uuidString:)),
            sourcePage: row["source_page"], sourceRowId: (row["source_row_id"] as String?).flatMap(UUID.init(uuidString:)),
            confirmed: (row["confirmed"] as Int) == 1,
            createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
    }

    /// 处方行事实列投影（再确认比对）：provenance 列（raw_text / source_page / medication_id / 时间戳 / ordinal）不比。
    static func factColumns(_ line: PrescriptionLine) -> [String?] {
        let texts: [String?] = [line.printedName, line.genericName, line.brandName, line.drugForm, line.spec, line.doseText, line.doseUnit,
                                line.quantityText, line.quantityUnit, line.frequencyText, line.routeText, line.durationText,
                                line.asNeededText, line.medicationNotes, line.note, line.insuranceCode, line.itemCodeText]
        let numbers: [Double?] = [line.startDate?.timeIntervalSince1970, line.endDate?.timeIntervalSince1970, line.unitPrice, line.amount]
        return texts.map(Self.normalized) + numbers.map { $0.map { String($0) } }
    }

    /// 已提交表头列（不含 advice_text）与已提交行的意图一致。
    static func prescriptionHeaderMatches(_ stored: Row, _ intent: EntityCardProjection.PrescriptionIntent) -> Bool {
        let texts: [(String?, String?)] = [
            (stored["hospital"], intent.hospital), (stored["doctor"], intent.doctor), (stored["department"], intent.department),
            (stored["prescription_no"], intent.prescriptionNo), (stored["prescription_type"], intent.prescriptionType),
            (stored["fee_type_text"], intent.feeTypeText), (stored["clinical_diagnosis"], intent.clinicalDiagnosis),
            (stored["pharmacist_names"], intent.pharmacistNames),
        ]
        guard texts.allSatisfy({ normalized($0.0) == normalized($0.1) }) else { return false }
        return (stored["prescribed_at"] as Double?) == intent.prescribedAt.timeIntervalSince1970
            && (stored["total_amount"] as Double?) == intent.totalAmount
    }

    /// 已提交行（按 source_row_id = 回执 row_id = v25 回填 id 定位）的事实列必须与其行意图一致；缺行或不一致 → false。
    static func prescriptionLinesMatch(_ intent: EntityCardProjection.PrescriptionIntent, header: String, patientId: String, db: Database) throws -> Bool {
        for item in intent.lines {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM prescription_line WHERE prescription_id = ? AND patient_id = ? AND (source_row_id = ? OR id = ?)
                """, arguments: [header, patientId, item.rowId.uuidString, item.rowId.uuidString]) else { return false }
            guard try factColumns(prescriptionLine(from: row)) == factColumns(item.line) else { return false }
        }
        return true
    }

    /// `claim_line` INSERT（行 id = 回执 row_id，与处方行同一确定性纪律）。
    static func insertClaimLine(_ line: EntityCardProjection.ClaimLineIntent, header: UUID, patientId: UUID, ordinal: Int,
                                page: Int, now: Date, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO claim_line (id, claim_item_id, patient_id, ordinal, item_name, item_code_text, insurance_code, spec, unit_price,
              quantity_text, quantity_unit, amount, fee_category_text, fee_at, executing_dept, self_pay_ratio_text, raw_text,
              source_page, source_row_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [line.rowId.uuidString, header.uuidString, patientId.uuidString, ordinal, line.itemName, line.itemCodeText,
                line.insuranceCode, line.spec, line.unitPrice, line.quantityText, line.quantityUnit, line.amount, line.feeCategoryText,
                line.feeAt?.timeIntervalSince1970, line.executingDept, line.selfPayRatioText, line.rawText,
                page, line.rowId.uuidString, now.timeIntervalSince1970])
    }

    static func factColumns(_ line: EntityCardProjection.ClaimLineIntent) -> [String?] {
        let texts: [String?] = [line.itemName, line.itemCodeText, line.insuranceCode, line.spec, line.quantityText, line.quantityUnit,
                                line.feeCategoryText, line.executingDept, line.selfPayRatioText]
        let numbers: [Double?] = [line.unitPrice, line.amount, line.feeAt?.timeIntervalSince1970]
        return texts.map(Self.normalized) + numbers.map { $0.map { String($0) } }
    }

    static func factColumns(claimLine row: Row) -> [String?] {
        let texts: [String?] = [row["item_name"], row["item_code_text"], row["insurance_code"], row["spec"], row["quantity_text"],
                                row["quantity_unit"], row["fee_category_text"], row["executing_dept"], row["self_pay_ratio_text"]]
        let numbers: [Double?] = [row["unit_price"], row["amount"], row["fee_at"]]
        return texts.map(Self.normalized) + numbers.map { $0.map { String($0) } }
    }

    static func claimHeaderMatches(_ stored: Row, _ intent: EntityCardProjection.ClaimIntent) -> Bool {
        let texts: [(String?, String?)] = [
            (stored["item_type"], intent.itemType), (stored["currency"], intent.currency), (stored["merchant"], intent.merchant),
            (stored["summary"], intent.summary), (stored["invoice_no"], intent.invoiceNo), (stored["insurance_type_text"], intent.insuranceTypeText),
        ]
        guard texts.allSatisfy({ normalized($0.0) == normalized($0.1) }) else { return false }
        let numbers: [(Double?, Double?)] = [
            (stored["amount"], intent.amount), (stored["date"], intent.date.timeIntervalSince1970),
            (stored["reimbursed_amount"], intent.reimbursedAmount), (stored["out_of_pocket"], intent.outOfPocket),
            (stored["personal_account_amount"], intent.personalAccountAmount),
        ]
        return numbers.allSatisfy { $0.0 == $0.1 }
    }

    static func claimLinesMatch(_ intent: EntityCardProjection.ClaimIntent, header: String, patientId: String, db: Database) throws -> Bool {
        for item in intent.lines {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM claim_line WHERE claim_item_id = ? AND patient_id = ? AND (source_row_id = ? OR id = ?)
                """, arguments: [header, patientId, item.rowId.uuidString, item.rowId.uuidString]) else { return false }
            guard factColumns(claimLine: row) == factColumns(item) else { return false }
        }
        return true
    }

    static func exportCommits(_ db: Database) throws -> [AuditRecord] {
        let audits = try String.fetchAll(db, sql: "SELECT raw_blocks FROM ocr_result WHERE engine_version = ?", arguments: [auditEngine])
        var byKey: [String: AuditRecord] = [:]
        for json in audits {
            let audit = try JSONDecoder().decode(AuditRecord.self, from: Data(json.utf8))
            let key = "\(audit.cardId.uuidString)/\(audit.rowId.uuidString)"
            guard byKey.updateValue(audit, forKey: key) == nil else { throw StoreError.corruptReceipt }
        }
        return try Row.fetchAll(db, sql: "SELECT * FROM ocr_card_commit ORDER BY created_at, card_id, row_id").map { row in
            try validateReceipt(row, db: db)
            let key = "\(row["card_id"] as String)/\(row["row_id"] as String)"
            guard var audit = byKey[key], audit.entityId.uuidString == (row["entity_id"] as String),
                  audit.patientId.uuidString == (row["patient_id"] as String), audit.documentId.uuidString == (row["document_file_id"] as String),
                  audit.pageIndex == (row["page_index"] as Int), audit.cardKind == (row["card_kind"] as String),
                  // 审计 JSON 的 entityTable（旧回执缺省 = cardKind）必须与搬运/写入的 entity_table 列一致；备份侧沿 JSON 值。
                  (audit.entityTable ?? audit.cardKind) == (row["entity_table"] as String),
                   audit.recordedAt.timeIntervalSince1970 == (row["created_at"] as Double) else { throw StoreError.corruptReceipt }
            audit.encounterId = (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:))
            return audit
        }
    }
}
#endif
