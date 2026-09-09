#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

/// FR6.9 / BR-001 / BR-003: the only atomic OCR card confirmation boundary.
public actor OCRCardStore {
    public static let supportedKinds: Set<String> = ["metric_sample", "encounter", "prescription"]
    static let auditEngine = "ocr-card-v22"
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

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
    }

    public func sourceRefs(entityId: UUID, patientId: UUID, cardKind: String) async throws -> [String] {
        guard Self.supportedKinds.contains(cardKind) else { throw StoreError.invalidCard }
        return try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM ocr_card_commit WHERE entity_id = ? AND patient_id = ? AND card_kind = ?
                ORDER BY document_file_id, page_index, row_id
                """, arguments: [entityId.uuidString, patientId.uuidString, cardKind])
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
                    try db.execute(sql: """
                        INSERT INTO encounter (id, patient_id, date, kind, hospital, department, doctor,
                          chief_complaint, diagnosis_text, advice_text, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [encounter.id.uuidString, patientId.uuidString, encounter.date.timeIntervalSince1970,
                            encounter.kind, encounter.hospital, encounter.department, encounter.doctor, encounter.chiefComplaint,
                            encounter.diagnosisText, encounter.adviceText, now.timeIntervalSince1970, now.timeIntervalSince1970])
                    entities[row.id] = encounter.id
                }
            case "prescription":
                if !accepted.isEmpty {
                    guard let intent = EntityCardProjection.prescriptionIntent(from: projectionCard) else { throw StoreError.invalidCard }
                    let existingIds = Set(receipts.map { $0["entity_id"] as String })
                    guard existingIds.count <= 1 else { throw StoreError.corruptReceipt }
                    let entity: UUID
                    if let existing = existingIds.first, let uuid = UUID(uuidString: existing) {
                        entity = uuid
                        var committedCard = snapshot
                        committedCard.rows = snapshot.rows.filter { committed.contains($0.id.uuidString) }
                        guard let prior = EntityCardProjection.prescriptionIntent(from: committedCard),
                              let stored = try Row.fetchOne(db, sql: "SELECT * FROM prescription WHERE id = ?", arguments: [existing]),
                              (stored["advice_text"] as String?) == prior.adviceText,
                              (stored["hospital"] as String?) == prior.hospital, (stored["doctor"] as String?) == prior.doctor,
                              (stored["prescribed_at"] as Double?) == prior.prescribedAt.timeIntervalSince1970 else {
                            throw StoreError.committedDataChanged
                        }
                        let addedIds = Set(accepted.map(\.id))
                        committedCard.rows = snapshot.rows.filter { committed.contains($0.id.uuidString) || addedIds.contains($0.id) }
                        guard let complete = EntityCardProjection.prescriptionIntent(from: committedCard) else { throw StoreError.invalidCard }
                        try db.execute(sql: "UPDATE prescription SET advice_text = ?, updated_at = ? WHERE id = ? AND patient_id = ?",
                                       arguments: [complete.adviceText, now.timeIntervalSince1970, existing, patientId.uuidString])
                        guard db.changesCount == 1 else { throw StoreError.committedDataChanged }
                    } else {
                        entity = UUID()
                        try db.execute(sql: """
                            INSERT INTO prescription (id, patient_id, document_file_id, source, hospital, doctor,
                              prescribed_at, advice_text, confirmed, created_at, updated_at)
                            VALUES (?, ?, ?, 'ocr', ?, ?, ?, ?, 1, ?, ?)
                            """, arguments: [entity.uuidString, patientId.uuidString, documentId.uuidString, intent.hospital,
                                intent.doctor, intent.prescribedAt.timeIntervalSince1970, intent.adviceText,
                                now.timeIntervalSince1970, now.timeIntervalSince1970])
                    }
                    for row in accepted { entities[row.id] = entity }
                }
            default: throw StoreError.invalidCard
            }
            for row in accepted {
                guard let entity = entities[row.id] else { throw StoreError.invalidCard }
                let audit = AuditRecord(cardId: card.id, rowId: row.id, patientId: patientId, documentId: documentId,
                    pageIndex: card.pageIndex, cardKind: card.kind, entityId: entity,
                    shared: snapshot.shared.filter(\.isConfirmed),
                    fields: row.fields.filter { $0.isConfirmed && $0.key != "metric_key" }, recordedAt: now)
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
            var remaining = snapshot; remaining.rows = residual
            return SaveResult(remainingCard: resolved ? nil : remaining, writtenCount: accepted.count, resolved: resolved, pendingCardId: id)
        }
    }

    static func mergeDraft(_ incoming: MatchedCard, previous: MatchedCard, committed: Set<String>) throws -> MatchedCard {
        guard incoming.id == previous.id, incoming.kind == previous.kind, incoming.pageIndex == previous.pageIndex,
              Set(incoming.rows.map(\.id)).count == incoming.rows.count else { throw StoreError.pendingIdentityMismatch }
        guard committed.isEmpty || previous.shared == incoming.shared else { throw StoreError.committedDataChanged }
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

    static func insertReceipt(_ audit: AuditRecord, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO ocr_card_commit (card_id, row_id, patient_id, document_file_id, page_index, card_kind, entity_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [audit.cardId.uuidString, audit.rowId.uuidString, audit.patientId.uuidString,
                audit.documentId.uuidString, audit.pageIndex, audit.cardKind, audit.entityId.uuidString, audit.recordedAt.timeIntervalSince1970])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(audit), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO ocr_result (id, document_file_id, page_index, raw_blocks, engine_version, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [UUID().uuidString, audit.documentId.uuidString, audit.pageIndex, json, auditEngine, audit.recordedAt.timeIntervalSince1970])
    }

    static func validateReceipt(_ row: Row, db: Database) throws {
        let kind: String = row["card_kind"], patient: String = row["patient_id"], document: String = row["document_file_id"]
        let page: Int = row["page_index"], entity: String = row["entity_id"]
        guard supportedKinds.contains(kind), page >= 0,
              try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM document_file d JOIN document_page p ON p.document_file_id = d.id
                WHERE d.id = ? AND d.patient_id = ? AND p.page_index = ? AND p.status = 'ok'
                """, arguments: [document, patient, page]) == 1,
              let fact = try Row.fetchOne(db, sql: "SELECT * FROM \(kind) WHERE id = ? AND patient_id = ?", arguments: [entity, patient]) else {
            throw StoreError.corruptReceipt
        }
        if kind == "metric_sample" {
            guard (fact["source_ref"] as String?) == "doc:\(document)#p\(page)", (fact["origin"] as String) == "hospital" else { throw StoreError.corruptReceipt }
        } else if kind == "prescription" {
            guard (fact["document_file_id"] as String?) == document, (fact["confirmed"] as Int) == 1 else { throw StoreError.corruptReceipt }
        }
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
            guard let audit = byKey[key], audit.entityId.uuidString == (row["entity_id"] as String),
                  audit.patientId.uuidString == (row["patient_id"] as String), audit.documentId.uuidString == (row["document_file_id"] as String),
                  audit.pageIndex == (row["page_index"] as Int), audit.cardKind == (row["card_kind"] as String),
                  audit.recordedAt.timeIntervalSince1970 == (row["created_at"] as Double) else { throw StoreError.corruptReceipt }
            return audit
        }
    }
}
#endif
