import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols

// binds: SU-M2-PENDINGCARD / SU-M1c-EXPORT (FR6.1 / FR6.9 / BR-001 / BR-003)
@MainActor
final class OcrCardStoreTests: XCTestCase {
    private func fixture() async throws -> (GRDBStore, UUID, UUID) {
        let store = try GRDBStore.inMemory()
        let patient = UUID()
        try await store.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'A', 'other', 0, 0)", arguments: [patient.uuidString])
        }
        let document = try await DocumentStore(writer: store.writer).save(
            patientId: patient, docType: "lab_report", sha256: "ocr-test", mimeType: "image/png",
            origin: "import", isSensitive: false, metaJSON: nil, title: "Report", grade: "C",
            pages: [.init(index: 0, text: "Original page"), .init(index: 1, text: "Second page")])
        return (store, patient, document)
    }

    private func receiptCard(encounter: UUID?) -> MatchedCard {
        MatchedCard(kind: "claim_item", pageIndex: 0,
            shared: [.init(key: "amount", value: "128.50"), .init(key: "currency", value: "CNY"),
                     .init(key: "date", value: "2026-09-11"), .init(key: "item_type", value: "invoice"),
                     .init(key: "merchant", value: "医院")], rows: [.init(fields: [])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete,
            encounterAssociation: encounter.map(EncounterAssociation.existing) ?? .none).confirmingAllFields()
    }

    func test_receiptAssociationSurvivesBackupAndAdoptRestoresChangedRelation() async throws {
        let (db, patient, document) = try await fixture()
        let encounters = EncounterStore(writer: db.writer)
        let e1 = try await encounters.upsert(encounter: EncounterDraft(patientId: patient, date: Date(), kind: "outpatient"))
        let e2 = try await encounters.upsert(encounter: EncounterDraft(patientId: patient, date: Date(), kind: "outpatient"))
        let cards = OCRCardStore(writer: db.writer)
        _ = try await cards.save(card: receiptCard(encounter: e1), patientId: patient, documentId: document)
        let exporter = ExportService(writer: db.writer)
        let backup = try await exporter.exportJSON()
        let claim = try XCTUnwrap(backup.claims?.first)
        try await cards.associate(kind: "claim_item", entityId: claim.id, patientId: patient, encounterId: e2)
        let conflicts = try await exporter.conflictReport(backup)
        try await exporter.importJSON(backup, resolutions: Dictionary(conflicts.map { ($0.id, ExportService.ConflictResolution.adopt) }, uniquingKeysWith: { first, _ in first }))
        let detail = try await cards.detail(kind: "claim_item", entityId: claim.id, patientId: patient)
        XCTAssertEqual(detail.encounterIDs, [e1])
        XCTAssertEqual(detail.sources.first?.pageIndex, 0)
        let fresh = try GRDBStore.inMemory()
        try await ExportService(writer: fresh.writer).importJSON(backup)
        let restored = try await OCRCardStore(writer: fresh.writer).detail(kind: "claim_item", entityId: claim.id, patientId: patient)
        XCTAssertEqual(restored.encounterIDs, [e1])
        XCTAssertEqual(restored.fields.first { $0.key == "amount" }?.value, "128.5")
    }

    func test_otherMembersEncounterCannotBeAttached() async throws {
        let (db, patient, document) = try await fixture()
        let other = UUID()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'Other', 'other', 0, 0)", arguments: [other.uuidString])
        }
        let encounter = try await EncounterStore(writer: db.writer).upsert(encounter: .init(patientId: other, date: Date(), kind: "outpatient"))
        do {
            _ = try await OCRCardStore(writer: db.writer).save(card: receiptCard(encounter: encounter), patientId: patient, documentId: document)
            XCTFail("Cross-member association must fail atomically")
        } catch OCRCardStore.StoreError.invalidAssociation {}
        let count = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM claim_item") }
        XCTAssertEqual(count, 0)
    }

    func test_explicitUnlinkedReceiptStaysUnlinkedWhenAnEncounterExists() async throws {
        let (db, patient, document) = try await fixture()
        _ = try await EncounterStore(writer: db.writer).upsert(encounter: .init(patientId: patient, date: Date(), kind: "outpatient", hospital: "医院"))
        _ = try await OCRCardStore(writer: db.writer).save(card: receiptCard(encounter: nil), patientId: patient, documentId: document)
        let linked = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM claim_item WHERE encounter_id IS NOT NULL") }
        XCTAssertEqual(linked, 0)
    }

    private func card(partial: Bool = false, reviewed: Bool = true) -> MatchedCard {
        var result = MatchedCard(kind: "metric_sample", pageIndex: 0,
            shared: [.init(key: "measured_at", value: "2020-01-02"), .init(key: "hospital", value: "Hospital")],
            rows: [MatchedCardRow(fields: [.init(key: "raw_label", value: "A"), .init(key: "value", value: "12", rawText: "A 1.2"), .init(key: "unit", value: "g/L")]),
                   MatchedCardRow(fields: [.init(key: "raw_label", value: "B"), .init(key: "value", value: partial ? "invalid" : "13"), .init(key: "unit", value: "g/L")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        if reviewed {
            for i in result.shared.indices { _ = result.shared[i].confirm() }
            for r in result.rows.indices {
                for f in result.rows[r].fields.indices { _ = result.rows[r].fields[f].confirm() }
            }
        }
        return result
    }

    func test_partialSaveRetainsSnapshotAndReplayDoesNotDuplicate() async throws {
        let (db, patient, document) = try await fixture()
        let writer = OCRCardStore(writer: db.writer)
        let original = card(partial: true)
        let first = try await writer.save(card: original, patientId: patient, documentId: document)
        XCTAssertEqual(first.writtenCount, 1)
        XCTAssertFalse(first.resolved)
        XCTAssertEqual(first.remainingCard?.rows.map(\.id), [original.rows[1].id])
        let fetched = try await PendingCardStore(writer: db.writer).card(id: first.pendingCardId)
        let pending = try XCTUnwrap(fetched)
        XCTAssertEqual(pending.partialData.card?.rows.count, 2)
        let replay = try await writer.save(card: original, patientId: patient, documentId: document, pendingCardId: first.pendingCardId)
        XCTAssertEqual(replay.writtenCount, 0)
        var remaining = try XCTUnwrap(replay.remainingCard)
        remaining.rows[0].fields[1].value = "14"
        _ = remaining.rows[0].fields[1].confirm()
        let last = try await writer.save(card: remaining, patientId: patient, documentId: document, pendingCardId: first.pendingCardId)
        XCTAssertEqual(last.writtenCount, 1)
        XCTAssertTrue(last.resolved)
        let count = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(count, 2)
        let status = try await PendingCardStore(writer: db.writer).card(id: first.pendingCardId)?.status
        XCTAssertEqual(status, "resolved")
    }

    func test_unreviewedCardOnlyCreatesDraft() async throws {
        let (db, patient, document) = try await fixture()
        let result = try await OCRCardStore(writer: db.writer).save(card: card(reviewed: false), patientId: patient, documentId: document)
        XCTAssertEqual(result.writtenCount, 0)
        XCTAssertFalse(result.resolved)
        let count = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(count, 0)
    }

    func test_recoveryMetadataCannotBecomeSearchOrAIExcerpt() async throws {
        let (db, patient, document) = try await fixture()
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE document_file SET title = NULL, ocr_text = NULL, notes = NULL, grade = 'C', meta_json = ? WHERE id = ?",
                           arguments: [#"{"ocr_review":"rejected zzzzz value"}"#, document.uuidString])
        }
        let search = GRDBSearchService(writer: db.writer)
        for query in ["z", "zz", "zzz"] {
            let hits = try await search.search(query, scope: DataAccessScope(patientIds: [patient]), limit: 10)
            XCTAssertTrue(hits.isEmpty, "Recovery metadata is never a searchable clinical fact")
        }
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE document_file SET ocr_text = 'zzzzz confirmed' WHERE id = ?", arguments: [document.uuidString])
        }
        let confirmed = try await search.search("z", scope: DataAccessScope(patientIds: [patient]), limit: 10)
        XCTAssertEqual(confirmed.count, 1)
        XCTAssertFalse(confirmed[0].snippet.contains("ocr_review"))
    }

    func test_coexistRemapsPendingOnlySnapshotCardIdentity() async throws {
        let (db, patient, document) = try await fixture()
        let pendingCard = card(reviewed: false)
        let cardJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pendingCard))
        let review = String(decoding: try JSONSerialization.data(withJSONObject: ["cards": [cardJSON]]), as: UTF8.self)
        let metadata = String(decoding: try JSONSerialization.data(withJSONObject: ["ocr_review": review]), as: UTF8.self)
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE document_file SET meta_json = ? WHERE id = ?", arguments: [metadata, document.uuidString])
        }
        let exporter = ExportService(writer: db.writer)
        let envelope = try await exporter.exportJSON()
        let conflicts = try await exporter.conflictReport(envelope)
        let resolutions = Dictionary(conflicts.map { ($0.id, ExportService.ConflictResolution.coexist) }, uniquingKeysWith: { first, _ in first })
        try await exporter.importJSON(envelope, resolutions: resolutions)
        let copy = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT id, patient_id, meta_json FROM document_file WHERE id != ?", arguments: [document.uuidString]) }
        let row = try XCTUnwrap(copy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((row["meta_json"] as String).utf8)) as? [String: Any])
        let reviewText = try XCTUnwrap(object["ocr_review"] as? String)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reviewText.utf8)) as? [String: Any])
        let cards = try XCTUnwrap(snapshot["cards"] as? [[String: Any]])
        XCTAssertNotEqual(cards.first?["id"] as? String, pendingCard.id.uuidString)
        XCTAssertNotEqual(row["patient_id"] as String, patient.uuidString)
    }

    func test_reviewedButUncommittedResidualSurvivesLaterAndResume() async throws {
        let (db, patient, document) = try await fixture()
        let writer = OCRCardStore(writer: db.writer)
        var original = card(partial: true)
        original.rows.append(MatchedCardRow(fields: [.init(key: "raw_label", value: "C"),
            .init(key: "value", value: "invalid"), .init(key: "unit", value: "g/L")]))
        let saved = try await writer.save(card: original, patientId: patient, documentId: document)
        var residual = try XCTUnwrap(saved.remainingCard)
        residual.rows[0].fields[1].value = "15"
        for index in residual.rows[0].fields.indices { _ = residual.rows[0].fields[index].confirm() }
        let pendingStore = PendingCardStore(writer: db.writer)
        _ = try await pendingStore.upsert(.init(patientId: patient, sourceType: "ocr", sourceDocId: document,
            sourcePage: 0, cardKind: "metric_sample", incompleteFields: [.init(key: "value", rowId: residual.rows[1].id)],
            partialData: .init(card: residual), rawText: "Original page"))
        let fetched = try await pendingStore.card(id: saved.pendingCardId)
        let pending = try XCTUnwrap(fetched)
        let resumed = try await writer.remainingCard(for: pending)
        XCTAssertEqual(resumed.rows.map(\.id), residual.rows.map(\.id))
        XCTAssertEqual(resumed.rows[0].fields[1].value, "15")
        let next = try await writer.save(card: resumed, patientId: patient, documentId: document, pendingCardId: pending.id)
        XCTAssertEqual(next.writtenCount, 1)
        XCTAssertEqual(next.remainingCard?.rows.map(\.id), [residual.rows[1].id])
    }

    func test_documentAndInitialPendingCardsStageAtomically() async throws {
        let (db, patient, _) = try await fixture()
        try await db.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_initial_card BEFORE INSERT ON pending_card BEGIN SELECT RAISE(ABORT, 'stage failure'); END")
        }
        do {
            _ = try await DocumentStore(writer: db.writer).save(patientId: patient, docType: "lab_report",
                sha256: "atomic-stage", mimeType: "image/png", origin: "import", isSensitive: true,
                metaJSON: nil, title: nil, grade: "D", pages: [.init(index: 0, text: "A 12 g/L")],
                cards: [card(reviewed: false)])
            XCTFail("Initial draft staging must fail with the document transaction")
        } catch { XCTAssertTrue(String(describing: error).contains("stage failure")) }
        let count = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM document_file WHERE sha256 = 'atomic-stage'") }
        XCTAssertEqual(count, 0)
    }

    func test_deferringEditedResidualPreservesCommittedRowsWithoutNewFacts() async throws {
        let (db, patient, document) = try await fixture()
        let original = card(partial: true)
        let result = try await OCRCardStore(writer: db.writer).save(card: original, patientId: patient, documentId: document)
        var residual = try XCTUnwrap(result.remainingCard)
        residual.rows[0].fields[1].value = "15"
        let draft = PendingCardDraft(patientId: patient, sourceType: "ocr", sourceDocId: document, sourcePage: 0,
                                     cardKind: residual.kind, incompleteFields: [], partialData: PendingCardPayload(card: residual), rawText: "Original page")
        _ = try await PendingCardStore(writer: db.writer).upsert(draft)
        let pending = try await PendingCardStore(writer: db.writer).card(id: result.pendingCardId)
        XCTAssertEqual(pending?.partialData.card?.rows.count, 2)
        XCTAssertEqual(pending?.partialData.card?.rows[1].fields[1].value, "15")
        let count = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(count, 1)
    }

    func test_restoredReceiptRejectsRematchedCardAndChangedReplay() async throws {
        let (db, patient, document) = try await fixture()
        let original = card()
        _ = try await OCRCardStore(writer: db.writer).save(card: original, patientId: patient, documentId: document)
        let envelope = try await ExportService(writer: db.writer).exportJSON()
        let target = try GRDBStore.inMemory()
        try await ExportService(writer: target.writer).importJSON(envelope)
        let writer = OCRCardStore(writer: target.writer)
        do {
            _ = try await writer.save(card: card(), patientId: patient, documentId: document)
            XCTFail("A new card identity must not bypass restored receipts")
        } catch {}
        var changed = original
        changed.rows[0].fields[1].value = "99"
        _ = changed.rows[0].fields[1].confirm()
        do {
            _ = try await writer.save(card: changed, patientId: patient, documentId: document)
            XCTFail("Changed committed data must not be silently ignored")
        } catch {}
        let replay = try await writer.save(card: original, patientId: patient, documentId: document)
        XCTAssertEqual(replay.writtenCount, 0)
        XCTAssertTrue(replay.resolved)
    }

    func test_resolutionFailureRollsBackFactsReceiptsAndAudit() async throws {
        let (db, patient, document) = try await fixture()
        try await db.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_ocr_resolution BEFORE UPDATE OF status ON pending_card WHEN NEW.status = 'resolved' BEGIN SELECT RAISE(ABORT, 'injected'); END")
        }
        do {
            _ = try await OCRCardStore(writer: db.writer).save(card: card(), patientId: patient, documentId: document)
            XCTFail("Expected injected resolution failure")
        } catch { XCTAssertTrue(String(describing: error).contains("injected")) }
        let counts = try await db.writer.read { db in
            try ["metric_sample", "ocr_card_commit", "ocr_result", "pending_card"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        XCTAssertEqual(counts, [0, 0, 0, 0])
    }

    func test_wrongOwnerAndMissingPageAreRejected() async throws {
        let (db, patient, document) = try await fixture()
        let writer = OCRCardStore(writer: db.writer)
        do {
            _ = try await writer.save(card: card(), patientId: UUID(), documentId: document)
            XCTFail("Wrong owner accepted")
        } catch {}
        let original = card()
        let wrongPage = MatchedCard(id: original.id, kind: original.kind, pageIndex: 99,
                                   shared: original.shared, rows: original.rows, allFieldCoverage: 1,
                                   requiredCoverage: 1, missingRequired: [], level: .complete)
        do {
            _ = try await writer.save(card: wrongPage, patientId: patient, documentId: document)
            XCTFail("Missing page accepted")
        } catch {}
    }

    func test_approvedCodeMustMatchStoredConceptIdentity() async throws {
        let (db, patient, document) = try await fixture()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO code_concept (id, canonical_code, coding_system, display_zh_hans, display_en, kind, bundle_version) VALUES ('ocr-test-code', 'correct', 'loinc', 'A', 'A', 'metric', 'test')")
        }
        var draft = card()
        draft.rows[0].fields[0].codeResolution = CodeResolution(conceptId: "ocr-test-code", canonicalCode: "wrong", codingSystem: .loinc,
            displayZhHans: "A", displayEn: "A", kind: .metric, canonicalUnit: "g/L", matchedVia: .curated, confidence: 1)
        _ = draft.rows[0].fields[0].approveCode(unit: "g/L")
        do {
            _ = try await OCRCardStore(writer: db.writer).save(card: draft, patientId: patient, documentId: document)
            XCTFail("Mismatched canonical code accepted")
        } catch HealthImportStore.ImportError.invalidValue {}
        draft.rows[0].fields[0].codeResolution = CodeResolution(conceptId: "ocr-test-code", canonicalCode: "correct", codingSystem: .snomedCT,
            displayZhHans: "A", displayEn: "A", kind: .metric, canonicalUnit: "g/L", matchedVia: .curated, confidence: 1)
        _ = draft.rows[0].fields[0].approveCode(unit: "g/L")
        do {
            _ = try await OCRCardStore(writer: db.writer).save(card: draft, patientId: patient, documentId: document)
            XCTFail("Mismatched coding system accepted")
        } catch HealthImportStore.ImportError.invalidValue {}
        let count = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(count, 0)
    }

    func test_auditContainsOriginalReviewedValueAndEntityIdentity() async throws {
        let (db, patient, document) = try await fixture()
        let original = card()
        _ = try await OCRCardStore(writer: db.writer).save(card: original, patientId: patient, documentId: document)
        let json = try await db.writer.read { try String.fetchOne($0, sql: "SELECT raw_blocks FROM ocr_result ORDER BY rowid LIMIT 1") }
        let audit = try JSONDecoder().decode(OCRCardStore.AuditRecord.self, from: Data(try XCTUnwrap(json).utf8))
        XCTAssertEqual(audit.cardId, original.id)
        XCTAssertEqual(audit.rowId, original.rows[0].id)
        XCTAssertEqual(audit.documentId, document)
        XCTAssertEqual(audit.fields.first { $0.key == "value" }?.rawText, "A 1.2")
        XCTAssertEqual(audit.fields.first { $0.key == "value" }?.value, "12")
    }

    func test_standaloneAuditRejectsWrongOwnerAndUnreviewedField() async throws {
        let (db, patient, document) = try await fixture()
        let writer = DocumentStore(writer: db.writer)
        var field = CandidateField(key: "value", displayLabel: "Value", rawText: "1.2", confidence: 0.7, value: "12")
        do {
            try await writer.saveOCRResult(documentId: document, patientId: patient, fields: [field], engineVersion: "test")
            XCTFail("Unreviewed field accepted")
        } catch {}
        _ = field.confirm()
        do {
            try await writer.saveOCRResult(documentId: document, patientId: UUID(), fields: [field], engineVersion: "test")
            XCTFail("Wrong owner accepted")
        } catch {}
        try await writer.saveOCRResult(documentId: document, patientId: patient, fields: [field], engineVersion: "test")
        let count = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ocr_result") }
        XCTAssertEqual(count, 1)
    }

    func test_coexistRestoresReceiptAndMetricToNewOwnedPage() async throws {
        let (db, patient, document) = try await fixture()
        _ = try await OCRCardStore(writer: db.writer).save(card: card(), patientId: patient, documentId: document)
        let exporter = ExportService(writer: db.writer)
        let envelope = try await exporter.exportJSON()
        let conflicts = try await exporter.conflictReport(envelope)
        let resolutions = Dictionary(conflicts.map { ($0.id, ExportService.ConflictResolution.coexist) }, uniquingKeysWith: { a, _ in a })
        try await exporter.importJSON(envelope, resolutions: resolutions)
        let rows = try await db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT c.patient_id, c.document_file_id, c.entity_id, m.patient_id AS metric_patient, m.source_ref FROM ocr_card_commit c JOIN metric_sample m ON m.id = c.entity_id")
        }
        XCTAssertEqual(rows.count, 4)
        for row in rows {
            XCTAssertEqual(row["patient_id"] as String, row["metric_patient"] as String)
            XCTAssertEqual(row["source_ref"] as String, "doc:\(row["document_file_id"] as String)#p0")
        }
    }

    func test_reattributionWithRetainedOCRFactsIsRefused() async throws {
        let (db, patient, document) = try await fixture()
        _ = try await OCRCardStore(writer: db.writer).save(card: card(), patientId: patient, documentId: document)
        let other = UUID()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'B', 'other', 0, 0)", arguments: [other.uuidString])
        }
        do {
            try await MemberDeletionService(writer: db.writer).reattributeDocument(documentId: document, from: patient, to: other)
            XCTFail("Retained facts must not cross owners")
        } catch {}
    }

    func test_adoptReplacesUnreferencedPagesAndRejectsMalformedPages() async throws {
        let (db, _, _) = try await fixture()
        let exporter = ExportService(writer: db.writer)
        var envelope = try await exporter.exportJSON()
        envelope.documents?[0].pages = [.init(index: 0, text: "Adopted", status: "ok")]
        let conflicts = try await exporter.conflictReport(envelope)
        let resolutions = Dictionary(conflicts.map { ($0.id, ExportService.ConflictResolution.adopt) }, uniquingKeysWith: { a, _ in a })
        try await exporter.importJSON(envelope, resolutions: resolutions)
        let pages = try await db.writer.read { try String.fetchAll($0, sql: "SELECT ocr_text FROM document_page") }
        XCTAssertEqual(pages, ["Adopted"])
        envelope.documents?[0].pages = [.init(index: 0, text: "A", status: "ok"), .init(index: 0, text: "B", status: "ok")]
        do {
            try await exporter.importJSON(envelope, resolutions: resolutions)
            XCTFail("Duplicate page indices accepted")
        } catch {}
        let unchanged = try await db.writer.read { try String.fetchAll($0, sql: "SELECT ocr_text FROM document_page") }
        XCTAssertEqual(unchanged, ["Adopted"])
    }

    func test_prescriptionRowsShareEntityAndRoundTripReviewedDateAdvice() async throws {
        let (db, patient, document) = try await fixture()
        var prescription = MatchedCard(kind: "prescription", pageIndex: 1,
            shared: [.init(key: "prescribed_at", value: "2020-01-02"), .init(key: "advice_text", value: "Reviewed advice")],
            rows: [MatchedCardRow(fields: [.init(key: "drug_name", value: "Drug A")]),
                   MatchedCardRow(fields: [.init(key: "drug_name", value: "Drug B")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        for i in prescription.shared.indices { _ = prescription.shared[i].confirm() }
        for i in prescription.rows.indices { _ = prescription.rows[i].fields[0].confirm() }
        let result = try await OCRCardStore(writer: db.writer).save(card: prescription, patientId: patient, documentId: document)
        XCTAssertEqual(result.writtenCount, 2)
        let envelope = try await ExportService(writer: db.writer).exportJSON()
        // v25（D1-4）：行实体随包（prescriptionLines），回执按 entity_table 指行。
        XCTAssertEqual(envelope.prescriptionLines?.map(\.printedName), ["Drug A", "Drug B"])
        XCTAssertEqual(Set((envelope.ocrCardCommits ?? []).map { $0.entityTable ?? $0.cardKind }), ["prescription_line"])
        let target = try GRDBStore.inMemory()
        try await ExportService(writer: target.writer).importJSON(envelope)
        let row = try await target.writer.read { try Row.fetchOne($0, sql: "SELECT * FROM prescription") }
        let restored = try XCTUnwrap(row)
        XCTAssertEqual(restored["advice_text"] as String, "Reviewed advice")   // 药品行不再折叠进 advice_text
        let calendar = Calendar(identifier: .gregorian)
        let expected = try XCTUnwrap(EntityCardProjection.parseDate("2020-01-02", calendar: calendar))
        XCTAssertEqual(restored["prescribed_at"] as Double, expected.timeIntervalSince1970)
        let lines = try await target.writer.read { try Row.fetchAll($0, sql: "SELECT ordinal, printed_name, confirmed FROM prescription_line ORDER BY ordinal") }
        XCTAssertEqual(lines.map { $0["ordinal"] as Int }, [0, 1])
        XCTAssertEqual(lines.map { $0["printed_name"] as String }, ["Drug A", "Drug B"])
        XCTAssertEqual(Set(lines.map { $0["confirmed"] as Int }), [1])
        let count = try await target.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(DISTINCT entity_id) FROM ocr_card_commit") }
        XCTAssertEqual(count, 2)   // 两行回执各指一行
        let headers = try await target.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT l.prescription_id) FROM ocr_card_commit c JOIN prescription_line l ON l.id = c.entity_id WHERE c.entity_table = 'prescription_line'")
        }
        XCTAssertEqual(headers, 1)   // 同一张卡的行回执回到同一表头
    }

    func test_partialPrescriptionCompletionPreservesOriginalRowOrder() async throws {
        let (db, patient, document) = try await fixture()
        var prescription = MatchedCard(kind: "prescription", pageIndex: 0,
            shared: [.init(key: "prescribed_at", value: "2020-01-02", grade: .userConfirmed)],
            rows: [MatchedCardRow(fields: [.init(key: "drug_name", value: "A", grade: .userConfirmed)]),
                   MatchedCardRow(fields: [.init(key: "drug_name", value: "B")]),
                   MatchedCardRow(fields: [.init(key: "drug_name", value: "C", grade: .userConfirmed)])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let writer = OCRCardStore(writer: db.writer)
        let first = try await writer.save(card: prescription, patientId: patient, documentId: document)
        XCTAssertEqual(first.writtenCount, 2)
        prescription = try XCTUnwrap(first.remainingCard)
        _ = prescription.rows[0].fields[0].confirm()
        let result = try await writer.save(card: prescription, patientId: patient, documentId: document, pendingCardId: first.pendingCardId)
        XCTAssertTrue(result.resolved)
        // v25：药品行落 prescription_line，行序 = 卡内原始行序（后补行落回其原位 ordinal），不再依赖 advice_text 拼串。
        let names = try await db.writer.read { try String.fetchAll($0, sql: "SELECT printed_name FROM prescription_line ORDER BY ordinal") }
        XCTAssertEqual(names, ["A", "B", "C"])
        let headers = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM prescription") }
        XCTAssertEqual(headers, 1)
        let advice = try await db.writer.read { try String.fetchOne($0, sql: "SELECT advice_text FROM prescription") }
        XCTAssertNil(advice)   // 无共享医嘱 → NULL；药品行绝不折叠回 advice_text
    }

    func test_memberDeletionArchivesAndCancelsPendingOCR() async throws {
        let (db, patient, document) = try await fixture()
        let result = try await OCRCardStore(writer: db.writer).save(card: card(reviewed: false), patientId: patient, documentId: document)
        let scheduler = InMemoryReminderScheduler()
        let key = "pending-\(result.pendingCardId)"
        try await scheduler.schedule(dose: key, at: Date().addingTimeInterval(3600), route: .pendingCard(result.pendingCardId))
        try await MemberDeletionService(writer: db.writer, scheduler: scheduler).deleteMember(patientId: patient, choice: .archivePlans)
        let pending = try await PendingCardStore(writer: db.writer).card(id: result.pendingCardId)
        XCTAssertEqual(pending?.status, "archived")
        let notifications = try await scheduler.pending()
        XCTAssertNil(notifications[key])
    }

    func test_encountersKeepSeparatePageReceiptsWithoutOverwritingGrouping() async throws {
        let (db, patient, document) = try await fixture()
        let writer = OCRCardStore(writer: db.writer)
        for page in 0...1 {
            let encounter = MatchedCard(kind: "encounter", pageIndex: page,
                shared: [.init(key: "date", value: "2020-01-02", grade: .userConfirmed),
                         .init(key: "kind", value: "outpatient", grade: .userConfirmed),
                         .init(key: "department", value: "Department \(page)", grade: .userConfirmed)],
                rows: [MatchedCardRow(fields: [])], allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
            let result = try await writer.save(card: encounter, patientId: patient, documentId: document)
            XCTAssertEqual(result.writtenCount, 1)
            let entity = try await db.writer.read { try String.fetchOne($0, sql: "SELECT entity_id FROM ocr_card_commit WHERE card_id = ?", arguments: [encounter.id.uuidString]) }
            let entityId = try XCTUnwrap(entity.flatMap(UUID.init(uuidString:)))
            let references = try await writer.sourceRefs(entityId: entityId, patientId: patient, cardKind: "encounter")
            XCTAssertEqual(references, [HospitalSample.sourceRef(documentId: document, pageIndex: page)])
        }
        let grouping = try await db.writer.read { try String.fetchOne($0, sql: "SELECT encounter_id FROM document_file WHERE id = ?", arguments: [document.uuidString]) }
        XCTAssertNil(grouping)
        let envelope = try await ExportService(writer: db.writer).exportJSON()
        let target = try GRDBStore.inMemory()
        try await ExportService(writer: target.writer).importJSON(envelope)
        let departments = try await target.writer.read { db in
            try String.fetchAll(db, sql: "SELECT e.department FROM ocr_card_commit c JOIN encounter e ON e.id = c.entity_id ORDER BY c.page_index")
        }
        XCTAssertEqual(departments, ["Department 0", "Department 1"])
    }

    func test_legacyOCRPrescriptionDoesNotInventDateOrPagesOnRestore() async throws {
        let (db, patient, document) = try await fixture()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO prescription (id, patient_id, document_file_id, source, advice_text, confirmed, created_at, updated_at) VALUES (?, ?, ?, 'ocr', 'Legacy advice', 1, 0, 0)",
                           arguments: [UUID().uuidString, patient.uuidString, document.uuidString])
        }
        var envelope = try await ExportService(writer: db.writer).exportJSON()
        envelope.documents = envelope.documents?.map { var d = $0; d.pages = nil; return d }
        let target = try GRDBStore.inMemory()
        try await ExportService(writer: target.writer).importJSON(envelope)
        let date = try await target.writer.read { try Double.fetchOne($0, sql: "SELECT prescribed_at FROM prescription") }
        let pages = try await target.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM document_page") }
        let prescriptions = try await target.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM prescription") }
        XCTAssertNil(date)
        XCTAssertEqual(pages, 0)
        XCTAssertEqual(prescriptions, 1)
    }

    // MARK: - v25 recognition-fact-lines（子项目 D · D1-3）：表头 + 行落库、entity_table 回执、lineDetail、associate 零行

    private func prescriptionCard(pageIndex: Int = 0, shared: [FieldDraft], rows: [[FieldDraft]]) -> MatchedCard {
        MatchedCard(kind: "prescription", pageIndex: pageIndex, shared: shared, rows: rows.map { MatchedCardRow(fields: $0) },
                    allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).confirmingAllFields()
    }

    private func tableCounts(_ db: GRDBStore, _ tables: [String]) async throws -> [Int] {
        try await db.writer.read { db in
            try tables.map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1 }
        }
    }

    func test_prescriptionCardWritesHeaderAndLinesWithLineReceipts() async throws {
        let (db, patient, document) = try await fixture()
        let card = prescriptionCard(
            shared: [.init(key: "prescribed_at", value: "2020-01-02"), .init(key: "prescription_type", value: "tcm"),
                     .init(key: "advice_text", value: "饭后服")],
            rows: [[.init(key: "drug_name", value: "Drug A"), .init(key: "dosage", value: "0.5", unit: "g"), .init(key: "quantity", value: "2", unit: "盒")],
                   [.init(key: "drug_name", value: "Drug B")]])
        let store = OCRCardStore(writer: db.writer)
        let result = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(result.writtenCount, 2)
        XCTAssertTrue(result.resolved)
        let lines = try await db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.ordinal, l.printed_name, l.dose_text, l.dose_unit, l.quantity_text, l.quantity_unit, l.source_row_id, l.confirmed, c.entity_table
                FROM prescription_line l JOIN ocr_card_commit c ON c.entity_id = l.id AND c.patient_id = l.patient_id ORDER BY l.ordinal
                """)
        }
        XCTAssertEqual(lines.map { $0["printed_name"] as String }, ["Drug A", "Drug B"])
        XCTAssertEqual(lines.map { $0["ordinal"] as Int }, [0, 1])
        XCTAssertEqual(lines[0]["dose_text"] as String?, "0.5")
        XCTAssertEqual(lines[0]["dose_unit"] as String?, "g")        // BR-006：原文 + 单位，不解析不换算
        XCTAssertEqual(lines[0]["quantity_text"] as String?, "2")
        XCTAssertEqual(lines[0]["quantity_unit"] as String?, "盒")
        XCTAssertEqual(lines.map { $0["source_row_id"] as String }, card.rows.map(\.id.uuidString))
        XCTAssertEqual(Set(lines.map { $0["confirmed"] as Int }), [1])
        XCTAssertEqual(Set(lines.map { $0["entity_table"] as String }), ["prescription_line"])
        let headerRow = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT id, prescription_type, advice_text FROM prescription") }
        let header = try XCTUnwrap(headerRow)
        XCTAssertEqual(header["prescription_type"] as String?, "tcm")
        XCTAssertEqual(header["advice_text"] as String?, "饭后服")   // 只承担共享医嘱，不再折叠药品行
        let headerId = try XCTUnwrap(UUID(uuidString: header["id"] as String))
        let detail = try await store.detail(kind: "prescription", entityId: headerId, patientId: patient)
        XCTAssertEqual(detail.sources.count, 1)   // 表头经行回执到达来源页
        XCTAssertEqual(detail.lines.map(\.printedName), ["Drug A", "Drug B"])
        XCTAssertEqual(detail.fields.first { $0.key == "prescription_type" }?.value, "tcm")
        let refs = try await store.sourceRefs(entityId: headerId, patientId: patient, cardKind: "prescription")
        XCTAssertEqual(refs, [HospitalSample.sourceRef(documentId: document, pageIndex: 0)])
        let cards = try await store.cards(documentId: document, patientId: patient)
        XCTAssertEqual(cards.map { $0.id }, [headerId])   // 行回执折叠为表头卡
        XCTAssertEqual(cards.map { $0.kind }, ["prescription"])
    }

    func test_prescriptionReconfirmSamePageIsIdempotent() async throws {
        let (db, patient, document) = try await fixture()
        let card = prescriptionCard(shared: [.init(key: "prescribed_at", value: "2020-01-02")],
                                    rows: [[.init(key: "drug_name", value: "Drug A")], [.init(key: "drug_name", value: "Drug B")]])
        let store = OCRCardStore(writer: db.writer)
        let first = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(first.writtenCount, 2)
        let replay = try await store.save(card: card, patientId: patient, documentId: document, pendingCardId: first.pendingCardId)
        XCTAssertEqual(replay.writtenCount, 0)
        XCTAssertTrue(replay.resolved)
        let counts = try await tableCounts(db, ["prescription", "prescription_line", "ocr_card_commit"])
        XCTAssertEqual(counts, [1, 2, 2])
    }

    func test_prescriptionCompletionRefusesTamperedCommittedLine() async throws {
        let (db, patient, document) = try await fixture()
        var card = MatchedCard(kind: "prescription", pageIndex: 0,
            shared: [.init(key: "prescribed_at", value: "2020-01-02", grade: .userConfirmed)],
            rows: [MatchedCardRow(fields: [.init(key: "drug_name", value: "A", grade: .userConfirmed), .init(key: "dosage", value: "0.5", unit: "g", grade: .userConfirmed)]),
                   MatchedCardRow(fields: [.init(key: "drug_name", value: "B")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let store = OCRCardStore(writer: db.writer)
        let first = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(first.writtenCount, 1)
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE prescription_line SET dose_text = '5' WHERE source_row_id = ?", arguments: [card.rows[0].id.uuidString])
        }
        card = try XCTUnwrap(first.remainingCard)
        _ = card.rows[0].fields[0].confirm()
        do {
            _ = try await store.save(card: card, patientId: patient, documentId: document, pendingCardId: first.pendingCardId)
            XCTFail("A committed line that no longer matches its receipt must not be silently extended")
        } catch OCRCardStore.StoreError.committedDataChanged {}
        let counts = try await tableCounts(db, ["prescription", "prescription_line", "ocr_card_commit"])
        XCTAssertEqual(counts, [1, 1, 1])
    }

    func test_legacyFoldedPrescriptionCompletesWithoutRewritingAdvice() async throws {
        let (db, patient, document) = try await fixture()
        var card = MatchedCard(kind: "prescription", pageIndex: 0,
            shared: [.init(key: "prescribed_at", value: "2020-01-02", grade: .userConfirmed), .init(key: "advice_text", value: "Reviewed advice", grade: .userConfirmed)],
            rows: [MatchedCardRow(fields: [.init(key: "drug_name", value: "Drug A", grade: .userConfirmed)]),
                   MatchedCardRow(fields: [.init(key: "drug_name", value: "Drug B")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let store = OCRCardStore(writer: db.writer)
        let first = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(first.writtenCount, 1)
        // 回放 v24 形态：回执（行 + 审计 JSON）指表头（v25 搬运 entity_table = card_kind、JSON 无 entityTable）、
        // advice_text 为旧版折叠串；已有行即 v25 回填产物（id = source_row_id = 回执 row_id）。
        let stored = try await db.writer.read { try String.fetchOne($0, sql: "SELECT id FROM prescription") }
        let headerId = try XCTUnwrap(stored)
        let headerUUID = try XCTUnwrap(UUID(uuidString: headerId))
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE ocr_card_commit SET entity_table = 'prescription', entity_id = ? WHERE card_kind = 'prescription'", arguments: [headerId])
            try db.execute(sql: "UPDATE prescription SET advice_text = ? WHERE id = ?", arguments: ["Reviewed advice\nDrug A", headerId])
            for row in try Row.fetchAll(db, sql: "SELECT id, raw_blocks FROM ocr_result WHERE engine_version = 'ocr-card-v22'") {
                var audit = try JSONDecoder().decode(OCRCardStore.AuditRecord.self, from: Data((row["raw_blocks"] as String).utf8))
                audit.entityTable = nil; audit.entityId = headerUUID
                try db.execute(sql: "UPDATE ocr_result SET raw_blocks = ? WHERE id = ?",
                               arguments: [String(decoding: try JSONEncoder().encode(audit), as: UTF8.self), row["id"] as String])
            }
        }
        card = try XCTUnwrap(first.remainingCard)
        _ = card.rows[0].fields[0].confirm()
        let completed = try await store.save(card: card, patientId: patient, documentId: document, pendingCardId: first.pendingCardId)
        XCTAssertEqual(completed.writtenCount, 1)
        XCTAssertTrue(completed.resolved)
        let advice = try await db.writer.read { try String.fetchOne($0, sql: "SELECT advice_text FROM prescription") }
        XCTAssertEqual(advice, "Reviewed advice\nDrug A")   // 旧折叠串原样保留：只补空，不猜回、不改写
        let tables = try await db.writer.read { try String.fetchAll($0, sql: "SELECT entity_table FROM ocr_card_commit") }
        XCTAssertEqual(Set(tables), ["prescription", "prescription_line"])
        let names = try await db.writer.read { try String.fetchAll($0, sql: "SELECT printed_name FROM prescription_line ORDER BY ordinal") }
        XCTAssertEqual(names, ["Drug A", "Drug B"])
        let detail = try await store.detail(kind: "prescription", entityId: headerUUID, patientId: patient)
        XCTAssertEqual(detail.sources.count, 1)
        XCTAssertEqual(detail.lines.count, 2)
    }

    func test_lineDetailReturnsLineHeaderAndProvenance() async throws {
        let (db, patient, document) = try await fixture()
        let card = prescriptionCard(pageIndex: 1, shared: [.init(key: "prescribed_at", value: "2020-01-02"), .init(key: "hospital", value: "市医院")],
                                    rows: [[.init(key: "drug_name", value: "Drug A"), .init(key: "frequency", value: "bid")]])
        let store = OCRCardStore(writer: db.writer)
        _ = try await store.save(card: card, patientId: patient, documentId: document)
        let stored = try await db.writer.read { try String.fetchOne($0, sql: "SELECT id FROM prescription_line") }
        let lineId = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(stored)))
        let detail = try await store.lineDetail(lineId: lineId, patientId: patient)
        XCTAssertEqual(detail.line.printedName, "Drug A")
        XCTAssertEqual(detail.line.frequencyText, "bid")
        XCTAssertTrue(detail.line.confirmed)
        XCTAssertEqual(detail.line.sourceRowId, card.rows[0].id)
        XCTAssertEqual(detail.header.kind, "prescription")
        XCTAssertEqual(detail.header.entityId, detail.line.prescriptionId)
        XCTAssertEqual(detail.header.fields.first { $0.key == "hospital" }?.value, "市医院")
        XCTAssertEqual(detail.source?.documentId, document)
        XCTAssertEqual(detail.source?.pageIndex, 1)
    }

    func test_lineDetailRejectsOtherMember() async throws {
        let (db, patient, document) = try await fixture()
        let other = UUID()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'B', 'other', 0, 0)", arguments: [other.uuidString])
        }
        let card = prescriptionCard(shared: [.init(key: "prescribed_at", value: "2020-01-02")], rows: [[.init(key: "drug_name", value: "Drug A")]])
        let store = OCRCardStore(writer: db.writer)
        _ = try await store.save(card: card, patientId: patient, documentId: document)
        let stored = try await db.writer.read { try String.fetchOne($0, sql: "SELECT id FROM prescription_line") }
        let lineId = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(stored)))
        do {
            _ = try await store.lineDetail(lineId: lineId, patientId: other)
            XCTFail("Another member must not read this line")
        } catch OCRCardStore.StoreError.invalidCard {}
        do {
            _ = try await store.lineDetail(lineId: UUID(), patientId: patient)
            XCTFail("Unknown line must not resolve")
        } catch OCRCardStore.StoreError.invalidCard {}
    }

    func test_associateZeroRowUpdateThrowsInvalidAssociation() async throws {
        let (db, patient, _) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        let encounter = try await EncounterStore(writer: db.writer).upsert(encounter: .init(patientId: patient, date: Date(), kind: "outpatient"))
        // 手工药品：无回执、无 encounter_id 列——两条 UPDATE 皆零行，不得伪装成功，也不得写审计。
        let medication = UUID()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO medication (id, patient_id, generic_name, unit_kind, created_at, updated_at) VALUES (?, ?, 'Manual', 'tablet', 0, 0)",
                           arguments: [medication.uuidString, patient.uuidString])
        }
        do {
            try await store.associate(kind: "medication", entityId: medication, patientId: patient, encounterId: encounter)
            XCTFail("Zero-row association must not report success")
        } catch OCRCardStore.StoreError.invalidAssociation {}
        let audits = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM audit_event WHERE entity_type = 'medication'") }
        XCTAssertEqual(audits, 0)
        do {
            try await store.associate(kind: "medication", entityId: UUID(), patientId: patient, encounterId: nil)
            XCTFail("Unknown entity must not report success")
        } catch OCRCardStore.StoreError.invalidCard {} catch OCRCardStore.StoreError.invalidAssociation {}
    }

    func test_claimCardWithFeeLinesWritesClaimLinesAndLineReceipts() async throws {
        let (db, patient, document) = try await fixture()
        let card = MatchedCard(kind: "claim_item", pageIndex: 0,
            shared: [.init(key: "amount", value: "30.5"), .init(key: "currency", value: "CNY"), .init(key: "date", value: "2026-09-11"),
                     .init(key: "item_type", value: "fee"), .init(key: "invoice_no", value: "No.001"), .init(key: "reimbursed_amount", value: "20")],
            rows: [MatchedCardRow(fields: [.init(key: "item_name", value: "血常规"), .init(key: "item_amount", value: "20.5"), .init(key: "item_quantity", value: "1", unit: "次")]),
                   MatchedCardRow(fields: [.init(key: "item_name", value: "挂号费"), .init(key: "item_amount", value: "10")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).confirmingAllFields()
        let store = OCRCardStore(writer: db.writer)
        let result = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(result.writtenCount, 2)
        let headerRow = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT id, invoice_no, reimbursed_amount, amount FROM claim_item") }
        let claim = try XCTUnwrap(headerRow)
        XCTAssertEqual(claim["invoice_no"] as String?, "No.001")
        XCTAssertEqual(claim["reimbursed_amount"] as Double?, 20)
        XCTAssertEqual(claim["amount"] as Double?, 30.5)
        let lines = try await db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.ordinal, l.item_name, l.amount, l.quantity_text, l.quantity_unit, c.entity_table
                FROM claim_line l JOIN ocr_card_commit c ON c.entity_id = l.id AND c.patient_id = l.patient_id ORDER BY l.ordinal
                """)
        }
        XCTAssertEqual(lines.map { $0["item_name"] as String }, ["血常规", "挂号费"])
        XCTAssertEqual(lines[0]["amount"] as Double?, 20.5)
        XCTAssertEqual(lines[0]["quantity_text"] as String?, "1")
        XCTAssertEqual(lines[0]["quantity_unit"] as String?, "次")
        XCTAssertEqual(Set(lines.map { $0["entity_table"] as String }), ["claim_line"])
        let headerId = try XCTUnwrap(UUID(uuidString: claim["id"] as String))
        let detail = try await store.detail(kind: "claim_item", entityId: headerId, patientId: patient)
        XCTAssertEqual(detail.sources.count, 1)
        XCTAssertEqual(detail.fields.first { $0.key == "invoice_no" }?.value, "No.001")
        let totals = try await ClaimStore(writer: db.writer).totals(patientId: patient)
        XCTAssertEqual(totals.itemCount, 1)   // 明细行不重复计入票面合计（FR13.7 纯事实）
    }

    func test_claimCardWithoutFeeLinesKeepsHeaderReceipt() async throws {
        let (db, patient, document) = try await fixture()
        _ = try await OCRCardStore(writer: db.writer).save(card: receiptCard(encounter: nil), patientId: patient, documentId: document)
        let receipt = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT c.entity_table FROM ocr_card_commit c JOIN claim_item i ON i.id = c.entity_id") }
        let row = try XCTUnwrap(receipt)
        XCTAssertEqual(row["entity_table"] as String, "claim_item")
        let counts = try await tableCounts(db, ["claim_line"])
        XCTAssertEqual(counts, [0])
    }

    func test_encounterCardPersistsNarrativeColumnsAndOnlyFillsEmptyOnes() async throws {
        let (db, patient, document) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        let first = MatchedCard(kind: "encounter", pageIndex: 0,
            shared: [.init(key: "date", value: "2020-01-02"), .init(key: "kind", value: "outpatient"),
                     .init(key: "past_history", value: "高血压 10 年"), .init(key: "allergy_history", value: "青霉素")],
            rows: [MatchedCardRow(fields: [])], allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).confirmingAllFields()
        _ = try await store.save(card: first, patientId: patient, documentId: document)
        let encounterRow = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT id, past_history, allergy_history, physical_exam FROM encounter") }
        let encounter = try XCTUnwrap(encounterRow)
        XCTAssertEqual(encounter["past_history"] as String?, "高血压 10 年")
        XCTAssertEqual(encounter["allergy_history"] as String?, "青霉素")
        XCTAssertNil(encounter["physical_exam"] as String?)
        let encounterId = try XCTUnwrap(UUID(uuidString: encounter["id"] as String))
        let second = MatchedCard(kind: "encounter", pageIndex: 1,
            shared: [.init(key: "date", value: "2020-01-02"), .init(key: "kind", value: "outpatient"),
                     .init(key: "past_history", value: "冲突值"), .init(key: "physical_exam", value: "BP 120/80")],
            rows: [MatchedCardRow(fields: [])], allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete,
            encounterAssociation: .existing(encounterId)).confirmingAllFields()
        _ = try await store.save(card: second, patientId: patient, documentId: document)
        let mergedRow = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT past_history, physical_exam FROM encounter WHERE id = ?", arguments: [encounterId.uuidString]) }
        let merged = try XCTUnwrap(mergedRow)
        XCTAssertEqual(merged["past_history"] as String?, "高血压 10 年")   // 已有叙事不被第二份原件覆盖（冲突值留在来源卡）
        XCTAssertEqual(merged["physical_exam"] as String?, "BP 120/80")     // 空列补齐
        let restored = try await EncounterStore(writer: db.writer).get(id: encounterId)
        XCTAssertEqual(restored?.allergyHistory, "青霉素")
    }

    func test_encounterStoreUpsertPersistsNarrativeFields() async throws {
        let (db, patient, _) = try await fixture()
        let encounters = EncounterStore(writer: db.writer)
        let id = try await encounters.upsert(encounter: EncounterDraft(patientId: patient, date: Date(), kind: "outpatient",
                                                                        presentIllness: "咳嗽 3 天", pastHistory: "高血压", allergyHistory: "青霉素"))
        let created = try await encounters.get(id: id)
        XCTAssertEqual(created?.presentIllness, "咳嗽 3 天")
        XCTAssertEqual(created?.pastHistory, "高血压")
        XCTAssertEqual(created?.allergyHistory, "青霉素")
        _ = try await encounters.upsert(encounter: EncounterDraft(id: id, patientId: patient, date: Date(), kind: "outpatient", physicalExam: "BP 120/80"))
        let updated = try await encounters.get(id: id)
        XCTAssertEqual(updated?.physicalExam, "BP 120/80")
        XCTAssertNil(updated?.pastHistory)   // 手工 upsert = 全量覆盖语义（与既有列一致）
    }

    func test_medicationPlanFromPrescriptionLineLinksStockLot() async throws {
        let (db, patient, document) = try await fixture()
        let card = prescriptionCard(shared: [.init(key: "prescribed_at", value: "2020-01-02")],
                                    rows: [[.init(key: "drug_name", value: "阿莫西林"), .init(key: "spec", value: "0.25g")]])
        _ = try await OCRCardStore(writer: db.writer).save(card: card, patientId: patient, documentId: document)
        let lineRow = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT id, prescription_id FROM prescription_line") }
        let line = try XCTUnwrap(lineRow)
        let lineId = try XCTUnwrap(UUID(uuidString: line["id"] as String))
        let headerId = try XCTUnwrap(UUID(uuidString: line["prescription_id"] as String))
        let composer = MedicationPlanComposer(writer: db.writer, audit: AuditLogWriter(writer: db.writer))
        let prescription = Prescription(id: headerId, patientId: patient, documentFileId: document, source: .ocr, genericName: "阿莫西林", spec: "0.25g",
                                        confirmedFields: PrescriptionConfirmation.criticalFieldKeys)
        let plan = MedicationPlanDraft(schedule: .fixed(times: ["08:00"]), startDate: Date())
        let ids = try await composer.createMedicationPlan(prescription: prescription, plan: plan,
                                                          initialLot: StockLotDraft(totalUnits: 12, unitKind: "capsule"), prescriptionLineId: lineId)
        let linked = try await db.writer.read { try String.fetchOne($0, sql: "SELECT prescription_line_id FROM stock_lot WHERE id = ?", arguments: [ids.3.uuidString]) }
        XCTAssertEqual(linked, lineId.uuidString)
        do {
            _ = try await composer.createMedicationPlan(prescription: prescription, plan: plan,
                                                        initialLot: StockLotDraft(totalUnits: 12, unitKind: "capsule"), prescriptionLineId: UUID())
            XCTFail("An unknown or other member's line must not be linked")
        } catch MedicationPlanComposer.ComposerError.lineNotFound {}
        let lots = try await tableCounts(db, ["stock_lot"])
        XCTAssertEqual(lots, [1])
    }

    // MARK: - v25 备份/恢复（子项目 D · D1-4）：EncounterExport 全列、行数组、entityTable 回执、拓扑序、旧包兼容

    func test_manualEncounterRoundTripsAllColumns() async throws {
        let (db, patient, _) = try await fixture()
        let encounters = EncounterStore(writer: db.writer)
        let id = try await encounters.upsert(encounter: EncounterDraft(patientId: patient, date: Date(timeIntervalSince1970: 1_700_000_000), kind: "outpatient",
            hospital: "H", department: "内科", doctor: "Dr", chiefComplaint: "咳", diagnosisText: "上感", adviceText: "多饮水",
            followUpRequirement: "一周后复诊", feeAmount: 35.5, presentIllness: "咳嗽 3 天", visitSummary: "对症处理", pastHistory: "高血压",
            physicalExam: "BP 120/80", allergyHistory: "青霉素"))
        let envelope = try await ExportService(writer: db.writer).exportJSON()
        let exported = try XCTUnwrap(envelope.encounters.first { $0.id == id })
        XCTAssertEqual(exported.hospital, "H")
        XCTAssertEqual(exported.pastHistory, "高血压")
        XCTAssertEqual(exported.feeAmount, 35.5)
        let target = try GRDBStore.inMemory()
        try await ExportService(writer: target.writer).importJSON(envelope)
        let sourceRow = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT * FROM encounter WHERE id = ?", arguments: [id.uuidString]) }
        let restoredRow = try await target.writer.read { try Row.fetchOne($0, sql: "SELECT * FROM encounter WHERE id = ?", arguments: [id.uuidString]) }
        let restored = try XCTUnwrap(restoredRow)
        XCTAssertEqual(restored, try XCTUnwrap(sourceRow))   // 全列逐字相等（含 created_at/updated_at）——此前手工就诊只剩 diagnosis_text
        let columns = ["hospital", "department", "doctor", "chief_complaint", "diagnosis_text", "advice_text", "follow_up_requirement",
                       "present_illness", "visit_summary", "past_history", "physical_exam", "allergy_history"]
        XCTAssertEqual(columns.map { restored[$0] as String? },
                       ["H", "内科", "Dr", "咳", "上感", "多饮水", "一周后复诊", "咳嗽 3 天", "对症处理", "高血压", "BP 120/80", "青霉素"])
        XCTAssertEqual(restored["fee_amount"] as Double?, 35.5)
    }

    func test_documentTypeKeyAndTitleSourceRoundTrip() async throws {
        let (db, _, document) = try await fixture()
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE document_file SET doc_type_key = 'lab_report', title_source = 'user' WHERE id = ?", arguments: [document.uuidString])
        }
        let envelope = try await ExportService(writer: db.writer).exportJSON()
        XCTAssertEqual(envelope.documents?.first?.docTypeKey, "lab_report")
        XCTAssertEqual(envelope.documents?.first?.titleSource, "user")
        let target = try GRDBStore.inMemory()
        try await ExportService(writer: target.writer).importJSON(envelope)
        let row = try await target.writer.read { try Row.fetchOne($0, sql: "SELECT doc_type_key, title_source FROM document_file WHERE id = ?", arguments: [document.uuidString]) }
        let restored = try XCTUnwrap(row)
        XCTAssertEqual(restored["doc_type_key"] as String?, "lab_report")
        XCTAssertEqual(restored["title_source"] as String?, "user")
    }

    func test_restoredPrescriptionReconfirmIsIdempotentAndReimportKeepsLineCount() async throws {
        let (db, patient, document) = try await fixture()
        let card = prescriptionCard(shared: [.init(key: "prescribed_at", value: "2020-01-02"), .init(key: "advice_text", value: "饭后服"),
                                             .init(key: "prescription_type", value: "tcm")],
                                    rows: [[.init(key: "drug_name", value: "Drug A"), .init(key: "dosage", value: "0.5", unit: "g")],
                                           [.init(key: "drug_name", value: "Drug B")]])
        _ = try await OCRCardStore(writer: db.writer).save(card: card, patientId: patient, documentId: document)
        let envelope = try await ExportService(writer: db.writer).exportJSON()
        XCTAssertEqual(envelope.ocrPrescriptions?.first?.prescriptionType, "tcm")
        let target = try GRDBStore.inMemory()
        try await ExportService(writer: target.writer).importJSON(envelope)
        let before = try await db.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM prescription_line ORDER BY ordinal") }
        let after = try await target.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM prescription_line ORDER BY ordinal") }
        XCTAssertEqual(after, before)   // 全列（含 dose_text/dose_unit/source_row_id/confirmed）逐字相等
        // 恢复库上再确认同一张卡：回执经行到达同一表头、行事实列一致 → 零写入、resolved（幂等）
        let replay = try await OCRCardStore(writer: target.writer).save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(replay.writtenCount, 0)
        XCTAssertTrue(replay.resolved)
        let afterReplay = try await tableCounts(target, ["prescription", "prescription_line", "ocr_card_commit"])
        XCTAssertEqual(afterReplay, [1, 2, 2])
        // 同库再导入同一备份（冲突全部 adopt）：行随表头裁决，UNIQUE(prescription_id, ordinal) 不撞车、行数不翻倍
        let exporter = ExportService(writer: target.writer)
        let conflicts = try await exporter.conflictReport(envelope)
        try await exporter.importJSON(envelope, resolutions: Dictionary(conflicts.map { ($0.id, ExportService.ConflictResolution.adopt) }, uniquingKeysWith: { a, _ in a }))
        let afterReimport = try await tableCounts(target, ["prescription", "prescription_line", "ocr_card_commit"])
        XCTAssertEqual(afterReimport, [1, 2, 2])
    }

    func test_coexistRemapsPrescriptionLinesWithTheirHeader() async throws {
        let (db, patient, document) = try await fixture()
        let card = prescriptionCard(shared: [.init(key: "prescribed_at", value: "2020-01-02")],
                                    rows: [[.init(key: "drug_name", value: "Drug A")], [.init(key: "drug_name", value: "Drug B")]])
        _ = try await OCRCardStore(writer: db.writer).save(card: card, patientId: patient, documentId: document)
        let exporter = ExportService(writer: db.writer)
        let envelope = try await exporter.exportJSON()
        let conflicts = try await exporter.conflictReport(envelope)
        try await exporter.importJSON(envelope, resolutions: Dictionary(conflicts.map { ($0.id, ExportService.ConflictResolution.coexist) }, uniquingKeysWith: { a, _ in a }))
        let counts = try await tableCounts(db, ["prescription", "prescription_line", "ocr_card_commit"])
        XCTAssertEqual(counts, [2, 4, 4])
        let rows = try await db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.prescription_id, l.patient_id, p.patient_id AS header_patient, c.patient_id AS receipt_patient
                FROM prescription_line l JOIN prescription p ON p.id = l.prescription_id
                JOIN ocr_card_commit c ON c.entity_id = l.id AND c.entity_table = 'prescription_line'
                """)
        }
        XCTAssertEqual(rows.count, 4)   // 每行恰有一条回执：并存副本的行 id 与表头 id 一同重写，主键/UNIQUE 不撞车
        for row in rows {
            XCTAssertEqual(row["patient_id"] as String, row["header_patient"] as String)
            XCTAssertEqual(row["patient_id"] as String, row["receipt_patient"] as String)
        }
        let perHeader = try await db.writer.read { try Int.fetchAll($0, sql: "SELECT COUNT(*) FROM prescription_line GROUP BY prescription_id") }
        XCTAssertEqual(perHeader, [2, 2])
    }

    func test_claimLinesRoundTripWithLineReceipts() async throws {
        let (db, patient, document) = try await fixture()
        let card = MatchedCard(kind: "claim_item", pageIndex: 0,
            shared: [.init(key: "amount", value: "30.5"), .init(key: "currency", value: "CNY"), .init(key: "date", value: "2026-09-11"),
                     .init(key: "item_type", value: "fee"), .init(key: "invoice_no", value: "No.001"), .init(key: "reimbursed_amount", value: "20")],
            rows: [MatchedCardRow(fields: [.init(key: "item_name", value: "血常规"), .init(key: "item_amount", value: "20.5"), .init(key: "item_quantity", value: "1", unit: "次")]),
                   MatchedCardRow(fields: [.init(key: "item_name", value: "挂号费"), .init(key: "item_amount", value: "10")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).confirmingAllFields()
        _ = try await OCRCardStore(writer: db.writer).save(card: card, patientId: patient, documentId: document)
        let envelope = try await ExportService(writer: db.writer).exportJSON()
        XCTAssertEqual(envelope.claimLines?.map(\.itemName), ["血常规", "挂号费"])
        XCTAssertEqual(envelope.claims?.first?.invoiceNo, "No.001")
        XCTAssertEqual(envelope.claims?.first?.reimbursedAmount, 20)
        let target = try GRDBStore.inMemory()
        try await ExportService(writer: target.writer).importJSON(envelope)
        let before = try await db.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM claim_line ORDER BY ordinal") }
        let after = try await target.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM claim_line ORDER BY ordinal") }
        XCTAssertEqual(after, before)
        let headerRow = try await target.writer.read { try Row.fetchOne($0, sql: "SELECT invoice_no, reimbursed_amount FROM claim_item") }
        let header = try XCTUnwrap(headerRow)
        XCTAssertEqual(header["invoice_no"] as String?, "No.001")
        XCTAssertEqual(header["reimbursed_amount"] as Double?, 20)
        let tables = try await target.writer.read { try String.fetchAll($0, sql: "SELECT entity_table FROM ocr_card_commit") }
        XCTAssertEqual(tables, ["claim_line", "claim_line"])
        let claimId = try XCTUnwrap(envelope.claims?.first?.id)
        let detail = try await OCRCardStore(writer: target.writer).detail(kind: "claim_item", entityId: claimId, patientId: patient)
        XCTAssertEqual(detail.sources.count, 1)
    }

    func test_backupRejectsCrossMemberOrDanglingPrescriptionLines() async throws {
        let (db, patient, document) = try await fixture()
        let other = UUID()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'B', 'other', 0, 0)", arguments: [other.uuidString])
        }
        let card = prescriptionCard(shared: [.init(key: "prescribed_at", value: "2020-01-02")], rows: [[.init(key: "drug_name", value: "Drug A")]])
        _ = try await OCRCardStore(writer: db.writer).save(card: card, patientId: patient, documentId: document)
        let envelope = try await ExportService(writer: db.writer).exportJSON()
        var crossMember = envelope
        crossMember.prescriptionLines?[0].patientId = other
        let target = try GRDBStore.inMemory()
        do {
            try await ExportService(writer: target.writer).importJSON(crossMember)
            XCTFail("A line owned by another member must not be restored under this prescription")
        } catch ExportService.ExportError.invalidOCRBackup {}
        var dangling = envelope
        dangling.prescriptionLines = []
        do {
            try await ExportService(writer: target.writer).importJSON(dangling)
            XCTFail("A line receipt whose line is missing from the envelope must be rejected")
        } catch ExportService.ExportError.invalidOCRBackup {}
        let counts = try await tableCounts(target, ["prescription", "prescription_line", "ocr_card_commit"])
        XCTAssertEqual(counts, [0, 0, 0])
    }

    func test_legacyEnvelopeWithoutV25KeysStillRestores() async throws {
        let (db, patient, document) = try await fixture()
        let encounterId = try await EncounterStore(writer: db.writer).upsert(encounter: EncounterDraft(patientId: patient,
            date: Date(timeIntervalSince1970: 1_700_000_000), kind: "outpatient", diagnosisText: "上感"))
        _ = try await OCRCardStore(writer: db.writer).save(card: card(), patientId: patient, documentId: document)
        let rx = prescriptionCard(pageIndex: 1, shared: [.init(key: "prescribed_at", value: "2020-01-02"), .init(key: "advice_text", value: "Reviewed advice")],
                                  rows: [[.init(key: "drug_name", value: "Drug A")]])
        _ = try await OCRCardStore(writer: db.writer).save(card: rx, patientId: patient, documentId: document)
        // 回放 v24 库形态：表头回执（entity_table = card_kind、审计 JSON 无 entityTable）+ 折叠 advice_text、无 prescription_line。
        let stored = try await db.writer.read { try String.fetchOne($0, sql: "SELECT id FROM prescription") }
        let headerId = try XCTUnwrap(stored)
        let headerUUID = try XCTUnwrap(UUID(uuidString: headerId))
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM prescription_line")
            try db.execute(sql: "UPDATE ocr_card_commit SET entity_table = 'prescription', entity_id = ? WHERE card_kind = 'prescription'", arguments: [headerId])
            try db.execute(sql: "UPDATE prescription SET advice_text = ? WHERE id = ?", arguments: ["Reviewed advice\nDrug A", headerId])
            for row in try Row.fetchAll(db, sql: "SELECT id, raw_blocks FROM ocr_result WHERE engine_version = 'ocr-card-v22'") {
                var audit = try JSONDecoder().decode(OCRCardStore.AuditRecord.self, from: Data((row["raw_blocks"] as String).utf8))
                guard audit.cardKind == "prescription" else { continue }
                audit.entityTable = nil; audit.entityId = headerUUID
                try db.execute(sql: "UPDATE ocr_result SET raw_blocks = ? WHERE id = ?",
                               arguments: [String(decoding: try JSONEncoder().encode(audit), as: UTF8.self), row["id"] as String])
            }
        }
        let exporter = ExportService(writer: db.writer)
        let current = try await exporter.exportJSON()
        XCTAssertEqual(current.schemaVersion, ExportService.Envelope.currentSchemaVersion)
        let data = try await exporter.encode(current)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // 剥掉全部 v25 键 → 旧包形态（schemaVersion 1）
        json["schemaVersion"] = 1
        json["prescriptionLines"] = nil
        json["claimLines"] = nil
        func strip(_ array: String, _ keys: [String]) {
            guard var rows = json[array] as? [[String: Any]] else { return }
            for index in rows.indices { for key in keys { rows[index][key] = nil } }
            json[array] = rows
        }
        strip("encounters", ["hospital", "department", "doctor", "chiefComplaint", "adviceText", "followUpRequirement", "feeAmount", "rescheduledFromId",
                             "presentIllness", "visitSummary", "pastHistory", "physicalExam", "allergyHistory", "createdAt", "updatedAt"])
        strip("ocrCardCommits", ["entityTable"])
        strip("documents", ["docTypeKey", "titleSource"])
        strip("ocrPrescriptions", ["department", "prescriptionNo", "prescriptionType", "feeTypeText", "clinicalDiagnosis", "pharmacistNames", "totalAmount"])
        strip("claims", ["reimbursedAmount", "outOfPocket", "personalAccountAmount", "invoiceNo", "insuranceTypeText"])
        let legacy = try await exporter.decode(try JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.prescriptionLines)
        XCTAssertNil(legacy.encounters.first?.hospital)
        XCTAssertTrue((legacy.ocrCardCommits ?? []).allSatisfy { $0.entityTable == nil })
        let target = try GRDBStore.inMemory()
        try await ExportService(writer: target.writer).importJSON(legacy)
        let diagnosis = try await target.writer.read { try String.fetchOne($0, sql: "SELECT diagnosis_text FROM encounter WHERE id = ?", arguments: [encounterId.uuidString]) }
        XCTAssertEqual(diagnosis, "上感")
        let advice = try await target.writer.read { try String.fetchOne($0, sql: "SELECT advice_text FROM prescription") }
        XCTAssertEqual(advice, "Reviewed advice\nDrug A")   // 旧折叠串原样恢复
        let counts = try await tableCounts(target, ["prescription", "prescription_line", "metric_sample"])
        XCTAssertEqual(counts, [1, 0, 2])   // 绝不从 advice_text 猜回行（BR-003）
        let tables = try await target.writer.read { try String.fetchAll($0, sql: "SELECT entity_table FROM ocr_card_commit ORDER BY entity_table") }
        XCTAssertEqual(tables, ["metric_sample", "metric_sample", "prescription"])   // 旧回执缺省 entity_table = card_kind
    }
}
