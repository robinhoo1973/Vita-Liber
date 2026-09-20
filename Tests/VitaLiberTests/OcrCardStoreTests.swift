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
        let (store, patient) = try await GRDBStore.inMemoryWithPatient()
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
            encounterAssociation: encounter.map(EncounterAssociation.existing) ?? .none).fullyConfirmed()
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
                   // v26（§C.5）：非数值 value（阴性 / <0.5）是合法定性结果、进 lab_result——「待复核行」改用缺失 value（必填缺席）表达。
                   MatchedCardRow(fields: [.init(key: "raw_label", value: "B"), .init(key: "value", value: partial ? "" : "13"), .init(key: "unit", value: "g/L")])],
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
            .init(key: "value", value: ""), .init(key: "unit", value: "g/L")]))
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
        let counts = try await tableCounts(db, ["metric_sample", "ocr_card_commit", "ocr_result", "pending_card"])
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
                    allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
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
        // 并发闭包外承接值（2026-09-20 告警清除：捕获 var card 在 Swift 6 是错误）
        let tamperRowId = card.rows[0].id.uuidString
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE prescription_line SET dose_text = '5' WHERE source_row_id = ?", arguments: [tamperRowId])
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
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
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
            rows: [MatchedCardRow(fields: [])], allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
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
            encounterAssociation: .existing(encounterId)).fullyConfirmed()
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
        let composer = MedicationPlanComposer(writer: db.writer)
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
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
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

    // MARK: - v26 clinical-episodes（子项目 D · D2-3）：住院卡建就诊事务、诊断/检查卡、检验分流、五数组备份

    private func singleRowCard(kind: String, pageIndex: Int = 0, shared: [FieldDraft], encounter: UUID? = nil) -> MatchedCard {
        MatchedCard(kind: kind, pageIndex: pageIndex, shared: shared, rows: [MatchedCardRow(fields: [])],
                    allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete,
                    encounterAssociation: encounter.map(EncounterAssociation.existing) ?? .unselected).fullyConfirmed()
    }

    private func hospitalizationCard(pageIndex: Int = 0, kind: String = "inpatient", encounter: UUID? = nil, extra: [FieldDraft] = []) -> MatchedCard {
        singleRowCard(kind: "hospitalization", pageIndex: pageIndex,
                      shared: [.init(key: "hospital", value: "市一院"), .init(key: "kind", value: kind), .init(key: "admit_at", value: "2024-03-01"),
                               .init(key: "admit_dept", value: "呼吸内科"), .init(key: "admit_diagnosis", value: "社区获得性肺炎")] + extra,
                      encounter: encounter)
    }

    private func labCard(pageIndex: Int = 0, encounter: UUID? = nil) -> MatchedCard {
        MatchedCard(kind: "metric_sample", pageIndex: pageIndex,
            shared: [.init(key: "measured_at", value: "2020-01-02"), .init(key: "hospital", value: "市一院"), .init(key: "lab_name", value: "检验科"),
                     .init(key: "report_no", value: "R-001"), .init(key: "specimen_type", value: "血清"), .init(key: "collected_at", value: "2020-01-01")],
            rows: [MatchedCardRow(fields: [.init(key: "raw_label", value: "A"), .init(key: "value", value: "12"), .init(key: "unit", value: "g/L"),
                                           .init(key: "ref_low", value: "3.5"), .init(key: "ref_high", value: "9.5"), .init(key: "abnormal_flag", value: "↑")]),
                   MatchedCardRow(fields: [.init(key: "raw_label", value: "HBsAg"), .init(key: "value", value: "阴性")]),
                   MatchedCardRow(fields: [.init(key: "raw_label", value: "CRP"), .init(key: "value", value: "<0.5"), .init(key: "unit", value: "mg/L"),
                                           .init(key: "reference_text", value: "0-5")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete,
            encounterAssociation: encounter.map(EncounterAssociation.existing) ?? .unselected).fullyConfirmed()
    }

    func test_hospitalizationCardCreatesInpatientEncounterAndRowInOneTransaction() async throws {
        let (db, patient, document) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        let card = hospitalizationCard(extra: [.init(key: "discharge_orders", value: "出院后一周复查"), .init(key: "inpatient_times", value: "2")])
        let result = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(result.writtenCount, 1)
        XCTAssertTrue(result.resolved)
        let joined = try await db.writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT h.id, h.hospital, h.admit_at, h.inpatient_times, h.discharge_orders, h.confirmed, h.source, e.kind, e.date, e.hospital AS e_hospital, e.department,
                       c.entity_table, c.encounter_id AS receipt_encounter
                FROM hospitalization h JOIN encounter e ON e.id = h.encounter_id
                JOIN ocr_card_commit c ON c.entity_id = h.id AND c.patient_id = h.patient_id
                """)
        }
        let row = try XCTUnwrap(joined)
        XCTAssertEqual(row["kind"] as String, "inpatient")                       // 文档键派生的就诊类型
        XCTAssertEqual(row["e_hospital"] as String?, "市一院")
        XCTAssertEqual(row["department"] as String?, "呼吸内科")                  // encounter.department = admit_dept
        XCTAssertEqual(row["date"] as Double, row["admit_at"] as Double)          // 就诊日期 = 入院日期
        XCTAssertEqual(row["inpatient_times"] as Int?, 2)
        XCTAssertEqual(row["discharge_orders"] as String?, "出院后一周复查")
        XCTAssertEqual(row["confirmed"] as Int, 1)
        XCTAssertEqual(row["source"] as String, "ocr")
        XCTAssertEqual(row["entity_table"] as String, "hospitalization")
        XCTAssertNotNil(row["receipt_encounter"] as String?)                     // 回执携带就诊关系
        let counts = try await tableCounts(db, ["encounter", "hospitalization", "ocr_card_commit"])
        XCTAssertEqual(counts, [1, 1, 1])
        let entityId = try XCTUnwrap(UUID(uuidString: row["id"] as String))
        let detail = try await store.detail(kind: "hospitalization", entityId: entityId, patientId: patient)
        XCTAssertEqual(detail.hospitalization?.admitDept, "呼吸内科")
        XCTAssertEqual(detail.fields.first { $0.key == "admit_at" }?.value, "2024-03-01")
        XCTAssertEqual(detail.encounterIDs.count, 1)
        XCTAssertFalse(detail.relationshipEditable)                              // 住院期随就诊而生，不可单独改挂
        let encounterId = try XCTUnwrap(detail.encounterIDs.first)
        let linked = try await EncounterStore(writer: db.writer).linkedCards(encounterId: encounterId, patientId: patient)
        XCTAssertEqual(linked.map(\.kind), [.hospitalization])
        XCTAssertEqual(linked.first?.summary, "市一院")
        // 幂等：同卡再确认零写入、不新建就诊
        let replay = try await store.save(card: card, patientId: patient, documentId: document, pendingCardId: result.pendingCardId)
        XCTAssertEqual(replay.writtenCount, 0)
        let counts1 = try await tableCounts(db, ["encounter", "hospitalization"])
        XCTAssertEqual(counts1, [1, 1])
    }

    func test_hospitalizationSecondOriginalOnlyFillsEmptyColumnsOfTheSameStay() async throws {
        let (db, patient, document) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        _ = try await store.save(card: hospitalizationCard(), patientId: patient, documentId: document)
        let encounterRow = try await db.writer.read { try String.fetchOne($0, sql: "SELECT encounter_id FROM hospitalization") }
        let encounterId = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(encounterRow)))
        // 出院小结（第二页）显式归属同一就诊：UNIQUE(encounter_id) 一次住院一行，只补空（医院冲突值留在来源卡）
        let discharge = singleRowCard(kind: "hospitalization", pageIndex: 1,
            shared: [.init(key: "hospital", value: "另一名称"), .init(key: "kind", value: "inpatient"), .init(key: "discharge_at", value: "2024-03-08"),
                     .init(key: "discharge_orders", value: "低盐饮食"), .init(key: "actual_days", value: "7")], encounter: encounterId)
        let result = try await store.save(card: discharge, patientId: patient, documentId: document)
        XCTAssertEqual(result.writtenCount, 1)
        let rows = try await db.writer.read { try Row.fetchAll($0, sql: "SELECT hospital, admit_at, discharge_at, discharge_orders, actual_days FROM hospitalization") }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["hospital"] as String?, "市一院")               // 已有列不被第二份原件覆盖
        XCTAssertNotNil(rows[0]["admit_at"] as Double?)
        XCTAssertNotNil(rows[0]["discharge_at"] as Double?)                     // 空列补齐
        XCTAssertEqual(rows[0]["discharge_orders"] as String?, "低盐饮食")
        XCTAssertEqual(rows[0]["actual_days"] as Int?, 7)
        let receipts = try await db.writer.read { try Row.fetchAll($0, sql: "SELECT DISTINCT entity_id, encounter_id FROM ocr_card_commit") }
        XCTAssertEqual(receipts.count, 1)                                         // 两张卡的回执指同一住院期、同一就诊
        XCTAssertEqual(receipts[0]["encounter_id"] as String?, encounterId.uuidString)
        let counts = try await tableCounts(db, ["encounter", "hospitalization", "ocr_card_commit"])
        XCTAssertEqual(counts, [1, 1, 2])
        let entityId = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(receipts[0]["entity_id"] as String?)))
        let detail = try await store.detail(kind: "hospitalization", entityId: entityId, patientId: patient)
        XCTAssertEqual(detail.sources.map(\.pageIndex), [0, 1])                 // 两份原件页都可回到
    }

    func test_daySurgeryCardDerivesDaySurgeryEncounterKindAndRejectsOtherMembersEncounter() async throws {
        let (db, patient, document) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        _ = try await store.save(card: hospitalizationCard(kind: "daySurgery"), patientId: patient, documentId: document)
        let kind = try await db.writer.read { try String.fetchOne($0, sql: "SELECT kind FROM encounter") }
        XCTAssertEqual(kind, EncounterKind.daySurgery.rawValue)
        let other = UUID()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'B', 'other', 0, 0)", arguments: [other.uuidString])
        }
        let foreign = try await EncounterStore(writer: db.writer).upsert(encounter: .init(patientId: other, date: Date(), kind: "inpatient"))
        do {
            _ = try await store.save(card: hospitalizationCard(pageIndex: 1, encounter: foreign), patientId: patient, documentId: document)
            XCTFail("Cross-member hospitalization must fail atomically")
        } catch OCRCardStore.StoreError.invalidAssociation {}
        let counts2 = try await tableCounts(db, ["hospitalization", "ocr_card_commit"])
        XCTAssertEqual(counts2, [1, 1])
    }

    func test_diagnosisCardWritesRowsLinkedToExplicitEncounterAndInheritsItsDate() async throws {
        let (db, patient, document) = try await fixture()
        let encounters = EncounterStore(writer: db.writer)
        let visit = Date(timeIntervalSince1970: 1_700_000_000)
        let encounterId = try await encounters.upsert(encounter: EncounterDraft(patientId: patient, date: visit, kind: "outpatient"))
        let card = MatchedCard(kind: "diagnosis", pageIndex: 0,
            shared: [.init(key: "diagnosis_type", value: "certificate")],
            rows: [MatchedCardRow(fields: [.init(key: "name", value: "急性支气管炎"), .init(key: "code_text", value: "J20.9"), .init(key: "code_system", value: "ICD-10")]),
                   MatchedCardRow(fields: [.init(key: "name", value: "高血压"), .init(key: "diagnosis_type", value: "secondary")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete,
            encounterAssociation: .existing(encounterId)).fullyConfirmed()
        let store = OCRCardStore(writer: db.writer)
        let result = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(result.writtenCount, 2)
        let rows = try await db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.id, d.ordinal, d.name, d.diagnosis_type, d.code_text, d.code_system_text, d.diagnosed_at, d.encounter_id, d.health_problem_id, d.confirmed, c.entity_table
                FROM diagnosis d JOIN ocr_card_commit c ON c.entity_id = d.id AND c.patient_id = d.patient_id ORDER BY d.ordinal
                """)
        }
        XCTAssertEqual(rows.map { $0["name"] as String }, ["急性支气管炎", "高血压"])
        XCTAssertEqual(rows.map { $0["diagnosis_type"] as String }, ["certificate", "secondary"])   // 行覆盖共享默认
        XCTAssertEqual(rows[0]["code_text"] as String?, "J20.9")
        XCTAssertEqual(rows[0]["code_system_text"] as String?, "ICD-10")
        XCTAssertEqual(Set(rows.map { $0["encounter_id"] as String? }), [encounterId.uuidString])
        XCTAssertEqual(Set(rows.map { $0["diagnosed_at"] as Double? }), [visit.timeIntervalSince1970])   // 继承显式归属就诊的日期
        XCTAssertTrue(rows.allSatisfy { ($0["health_problem_id"] as String?) == nil })              // 只由用户「采用为健康问题」回填
        XCTAssertEqual(Set(rows.map { $0["entity_table"] as String }), ["diagnosis"])
        XCTAssertEqual(rows.map { $0["id"] as String }, card.rows.map(\.id.uuidString))            // id = 回执 row_id（确定性）
        let firstId = try XCTUnwrap(UUID(uuidString: rows[0]["id"] as String))
        let detail = try await store.detail(kind: "diagnosis", entityId: firstId, patientId: patient)
        XCTAssertEqual(detail.diagnoses.map(\.name), ["急性支气管炎", "高血压"])                  // 同卡诊断清单
        XCTAssertEqual(detail.encounterIDs, [encounterId])
        XCTAssertTrue(detail.relationshipEditable)
        let linked = try await encounters.linkedCards(encounterId: encounterId, patientId: patient)
        XCTAssertEqual(Set(linked.filter { $0.kind == .diagnosis }.map(\.summary)), ["急性支气管炎", "高血压"])
        let candidates = HealthProblemCandidate.from(diagnoses: detail.diagnoses)
        XCTAssertEqual(candidates.map(\.name), ["急性支气管炎", "高血压"])
    }

    func test_diagnosisCompletionRefusesTamperedCommittedRow() async throws {
        let (db, patient, document) = try await fixture()
        var card = MatchedCard(kind: "diagnosis", pageIndex: 0, shared: [],
            rows: [MatchedCardRow(fields: [.init(key: "name", value: "A", grade: .userConfirmed)]),
                   MatchedCardRow(fields: [.init(key: "name", value: "B")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let store = OCRCardStore(writer: db.writer)
        let first = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(first.writtenCount, 1)
        XCTAssertFalse(first.resolved)
        // 并发闭包外承接值（2026-09-20 告警清除：捕获 var card 在 Swift 6 是错误）
        let tamperRowId = card.rows[0].id.uuidString
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE diagnosis SET name = 'tampered' WHERE id = ?", arguments: [tamperRowId])
        }
        card = try XCTUnwrap(first.remainingCard)
        _ = card.rows[0].fields[0].confirm()
        do {
            _ = try await store.save(card: card, patientId: patient, documentId: document, pendingCardId: first.pendingCardId)
            XCTFail("A committed diagnosis that no longer matches its receipt must not be silently extended")
        } catch OCRCardStore.StoreError.committedDataChanged {}
        let counts3 = try await tableCounts(db, ["diagnosis", "ocr_card_commit"])
        XCTAssertEqual(counts3, [1, 1])
    }

    func test_examReportCardWritesReportWithVerbatimFindingsAndImpression() async throws {
        let (db, patient, document) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        let card = singleRowCard(kind: "exam_report", shared: [
            .init(key: "report_type", value: "ct"), .init(key: "hospital", value: "市一院"), .init(key: "exam_part", value: "胸部"),
            .init(key: "exam_at", value: "2024-03-02"), .init(key: "findings", value: "双肺纹理增粗。"),
            .init(key: "impression", value: "双肺炎性改变，建议复查。"), .init(key: "report_doctor", value: "王医生")])
        let result = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(result.writtenCount, 1)
        let stored = try await db.writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT r.id, r.report_type, r.exam_part, r.findings, r.impression, r.report_doctor, r.confirmed, r.source, r.document_file_id, c.entity_table
                FROM exam_report r JOIN ocr_card_commit c ON c.entity_id = r.id AND c.patient_id = r.patient_id
                """)
        }
        let row = try XCTUnwrap(stored)
        XCTAssertEqual(row["report_type"] as String, "ct")
        XCTAssertEqual(row["findings"] as String?, "双肺纹理增粗。")
        XCTAssertEqual(row["impression"] as String?, "双肺炎性改变，建议复查。")   // 原文，无 critical_value_flag
        XCTAssertEqual(row["report_doctor"] as String?, "王医生")
        XCTAssertEqual(row["confirmed"] as Int, 1)
        XCTAssertEqual(row["source"] as String, "ocr")
        XCTAssertEqual(row["document_file_id"] as String?, document.uuidString)
        XCTAssertEqual(row["entity_table"] as String, "exam_report")
        let entityId = try XCTUnwrap(UUID(uuidString: row["id"] as String))
        let detail = try await store.detail(kind: "exam_report", entityId: entityId, patientId: patient)
        XCTAssertEqual(detail.examReport?.examPart, "胸部")
        XCTAssertEqual(detail.fields.first { $0.key == "exam_at" }?.value, "2024-03-02")
        XCTAssertEqual(detail.fields.first { $0.key == "impression" }?.value, "双肺炎性改变，建议复查。")
        XCTAssertEqual(detail.sources.count, 1)
        let cards = try await store.cards(documentId: document, patientId: patient)
        XCTAssertEqual(cards.map { $0.kind }, ["exam_report"])
        let encounter = try await EncounterStore(writer: db.writer).upsert(encounter: .init(patientId: patient, date: Date(), kind: "outpatient"))
        try await store.associate(kind: "exam_report", entityId: entityId, patientId: patient, encounterId: encounter)
        let linked = try await EncounterStore(writer: db.writer).linkedCards(encounterId: encounter, patientId: patient)
        XCTAssertEqual(linked.map(\.kind), [.examReport])
    }

    func test_labCardSplitsNumericAndQualitativeRowsUnderOneReport() async throws {
        let (db, patient, document) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        let card = labCard()
        let result = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(result.writtenCount, 3)
        XCTAssertTrue(result.resolved)
        let header = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT * FROM lab_report") }
        let report = try XCTUnwrap(header)
        XCTAssertEqual(report["id"] as String, card.id.uuidString)                 // 表头 id = 卡 id（与 v26 回填同规则）
        XCTAssertEqual(report["source_card_id"] as String?, card.id.uuidString)
        XCTAssertEqual(report["lab_name"] as String?, "检验科")
        XCTAssertEqual(report["report_no"] as String?, "R-001")
        XCTAssertEqual(report["specimen_type"] as String?, "血清")
        XCTAssertNotNil(report["collected_at"] as Double?)
        XCTAssertEqual(report["confirmed"] as Int, 1)
        let samples = try await db.writer.read { try Row.fetchAll($0, sql: "SELECT raw_label, value, unit, lab_report_id, abnormal_flag, ref_low, measured_at FROM metric_sample") }
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0]["raw_label"] as String?, "A")
        XCTAssertEqual(samples[0]["value"] as Double, 12)
        XCTAssertEqual(samples[0]["lab_report_id"] as String?, card.id.uuidString)
        XCTAssertEqual(samples[0]["abnormal_flag"] as String?, "↑")                  // 打印标记原样落库
        XCTAssertEqual(samples[0]["ref_low"] as Double?, 3.5)
        XCTAssertEqual(samples[0]["measured_at"] as Double, report["collected_at"] as Double)   // measured_at = collected_at ?? reported_at
        let results = try await db.writer.read { try Row.fetchAll($0, sql: "SELECT item_name, result_text, comparator, unit, reference_text, ordinal, id FROM lab_result ORDER BY ordinal") }
        XCTAssertEqual(results.map { $0["item_name"] as String }, ["HBsAg", "CRP"])
        XCTAssertEqual(results.map { $0["result_text"] as String }, ["阴性", "<0.5"])   // 原文，不折数值
        XCTAssertEqual(results.map { $0["comparator"] as String? }, [nil, "<"])
        XCTAssertEqual(results[1]["unit"] as String?, "mg/L")
        XCTAssertEqual(results[1]["reference_text"] as String?, "0-5")
        XCTAssertEqual(results.map { $0["ordinal"] as Int }, [1, 2])                  // 卡内行序（含数值行）
        XCTAssertEqual(results.map { $0["id"] as String }, [card.rows[1].id.uuidString, card.rows[2].id.uuidString])
        let tables = try await db.writer.read { try String.fetchAll($0, sql: "SELECT entity_table FROM ocr_card_commit ORDER BY entity_table") }
        XCTAssertEqual(tables, ["lab_result", "lab_result", "metric_sample"])          // 回执按行分流
        // 读面：一张卡折叠为一份报告；报告详情 = 表头 + 数值行 + 定性行
        let cards = try await store.cards(documentId: document, patientId: patient)
        XCTAssertEqual(cards.map { $0.kind }, ["lab_report"])
        XCTAssertEqual(cards.map { $0.id }, [card.id])
        let detail = try await store.detail(kind: "lab_report", entityId: card.id, patientId: patient)
        XCTAssertEqual(detail.fields.first { $0.key == "lab_name" }?.value, "检验科")
        XCTAssertEqual(detail.fields.first { $0.key == "collected_at" }?.value, "2020-01-01")
        XCTAssertEqual(detail.labReport?.samples.map(\.rawLabel), ["A"])
        XCTAssertEqual(detail.labReport?.samples.first?.abnormalFlag, "↑")
        XCTAssertEqual(detail.labReport?.results.map(\.resultText), ["阴性", "<0.5"])
        XCTAssertEqual(detail.sources.count, 1)
        XCTAssertTrue(detail.relationshipEditable)
        let storedSample = try await db.writer.read { try String.fetchOne($0, sql: "SELECT id FROM metric_sample") }
        let sampleId = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(storedSample)))
        let sampleDetail = try await store.detail(kind: "metric_sample", entityId: sampleId, patientId: patient)
        XCTAssertEqual(sampleDetail.fields.first { $0.key == "abnormal_flag" }?.value, "↑")
        XCTAssertEqual(sampleDetail.fields.first { $0.key == "raw_label" }?.value, "A")    // 行键仍进详情（lineTable 不再误判检验卡）
        XCTAssertEqual(sampleDetail.labReport?.results.count, 2)
        // 幂等：同卡再确认零写入、不新建表头/行
        let replay = try await store.save(card: card, patientId: patient, documentId: document, pendingCardId: result.pendingCardId)
        XCTAssertEqual(replay.writtenCount, 0)
        let counts4 = try await tableCounts(db, ["lab_report", "metric_sample", "lab_result", "ocr_card_commit"])
        XCTAssertEqual(counts4, [1, 1, 2, 3])
        // 表头改挂就诊：表头 encounter_id + 其全部行回执同事务
        let encounter = try await EncounterStore(writer: db.writer).upsert(encounter: .init(patientId: patient, date: Date(), kind: "outpatient"))
        try await store.associate(kind: "lab_report", entityId: card.id, patientId: patient, encounterId: encounter)
        let linkedReceipts = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ocr_card_commit WHERE encounter_id = ?", arguments: [encounter.uuidString]) }
        XCTAssertEqual(linkedReceipts, 3)
        let linked = try await EncounterStore(writer: db.writer).linkedCards(encounterId: encounter, patientId: patient)
        XCTAssertEqual(linked.map(\.kind), [.labReport])                              // 数值行不再逐行重复列出
    }

    func test_labCardPartialCompletionReusesHeaderAndRefusesTamperedRows() async throws {
        let (db, patient, document) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        var card = MatchedCard(kind: "metric_sample", pageIndex: 0,
            shared: [.init(key: "measured_at", value: "2020-01-02", grade: .userConfirmed)],
            rows: [MatchedCardRow(fields: [.init(key: "raw_label", value: "HBsAg", grade: .userConfirmed), .init(key: "value", value: "阴性", grade: .userConfirmed)]),
                   MatchedCardRow(fields: [.init(key: "raw_label", value: "A", grade: .userConfirmed), .init(key: "value", value: "12", grade: .userConfirmed),
                                           .init(key: "unit", value: "g/L")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let first = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(first.writtenCount, 1)                                          // 定性行先落；数值行 unit 未确认 → 待复核
        let counts5 = try await tableCounts(db, ["lab_report", "lab_result", "metric_sample"])
        XCTAssertEqual(counts5, [1, 1, 0])
        var completion = try XCTUnwrap(first.remainingCard)
        _ = completion.rows[0].fields[2].confirm()
        let second = try await store.save(card: completion, patientId: patient, documentId: document, pendingCardId: first.pendingCardId)
        XCTAssertEqual(second.writtenCount, 1)
        XCTAssertTrue(second.resolved)
        let counts6 = try await tableCounts(db, ["lab_report", "lab_result", "metric_sample"])
        XCTAssertEqual(counts6, [1, 1, 1])   // 同卡复用同一表头
        // 篡改已提交定性行后再确认 → committedDataChanged（不在篡改事实上续写）
        card = MatchedCard(kind: "metric_sample", pageIndex: 1,
            shared: [.init(key: "measured_at", value: "2020-01-03", grade: .userConfirmed)],
            rows: [MatchedCardRow(fields: [.init(key: "raw_label", value: "HCV", grade: .userConfirmed), .init(key: "value", value: "阳性", grade: .userConfirmed)]),
                   MatchedCardRow(fields: [.init(key: "raw_label", value: "B", grade: .userConfirmed), .init(key: "value", value: "1", grade: .userConfirmed),
                                           .init(key: "unit", value: "g/L")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let partial = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(partial.writtenCount, 1)
        // 并发闭包外承接值（2026-09-20 告警清除：捕获 var card 在 Swift 6 是错误）
        let tamperRowId = card.rows[0].id.uuidString
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE lab_result SET result_text = '弱阳性' WHERE id = ?", arguments: [tamperRowId])
        }
        completion = try XCTUnwrap(partial.remainingCard)
        _ = completion.rows[0].fields[2].confirm()
        do {
            _ = try await store.save(card: completion, patientId: patient, documentId: document, pendingCardId: partial.pendingCardId)
            XCTFail("A tampered committed lab row must block completion")
        } catch OCRCardStore.StoreError.committedDataChanged {}
        let counts7 = try await tableCounts(db, ["lab_report", "lab_result", "metric_sample"])
        XCTAssertEqual(counts7, [2, 2, 1])
    }

    func test_clinicalEpisodesRoundTripThroughBackupAndReimportIsIdempotent() async throws {
        let (db, patient, document) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        _ = try await store.save(card: hospitalizationCard(extra: [.init(key: "discharge_at", value: "2024-03-08")]), patientId: patient, documentId: document)
        let encounterRow = try await db.writer.read { try String.fetchOne($0, sql: "SELECT encounter_id FROM hospitalization") }
        let encounterId = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(encounterRow)))
        let diagnosis = MatchedCard(kind: "diagnosis", pageIndex: 1, shared: [.init(key: "diagnosis_type", value: "discharge")],
            rows: [MatchedCardRow(fields: [.init(key: "name", value: "社区获得性肺炎"), .init(key: "code_text", value: "J18.9")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete, encounterAssociation: .existing(encounterId)).fullyConfirmed()
        _ = try await store.save(card: diagnosis, patientId: patient, documentId: document)
        _ = try await store.save(card: singleRowCard(kind: "exam_report", pageIndex: 1, shared: [
            .init(key: "report_type", value: "xray"), .init(key: "reported_at", value: "2024-03-03"), .init(key: "impression", value: "未见异常")],
            encounter: encounterId), patientId: patient, documentId: document)
        let lab = labCard(pageIndex: 0, encounter: encounterId)
        _ = try await store.save(card: lab, patientId: patient, documentId: document)
        let tables = ["encounter", "hospitalization", "diagnosis", "exam_report", "lab_report", "lab_result", "metric_sample", "ocr_card_commit"]
        let counts8 = try await tableCounts(db, tables)
        XCTAssertEqual(counts8, [1, 1, 1, 1, 1, 2, 1, 6])
        let exporter = ExportService(writer: db.writer)
        let envelope = try await exporter.exportJSON()
        XCTAssertEqual(envelope.schemaVersion, 2)                                      // 只增可选键，版本不变
        XCTAssertEqual(envelope.hospitalizations?.count, 1)
        XCTAssertEqual(envelope.hospitalizations?.first?.encounterId, encounterId)
        XCTAssertEqual(envelope.diagnoses?.map(\.name), ["社区获得性肺炎"])
        XCTAssertEqual(envelope.examReports?.map(\.reportType), ["xray"])
        XCTAssertEqual(envelope.labReports?.count, 1)
        XCTAssertEqual(envelope.labResults?.map(\.resultText), ["阴性", "<0.5"])
        XCTAssertEqual(envelope.metrics.first?.labReportId, envelope.labReports?.first?.id)
        XCTAssertEqual(envelope.metrics.first?.abnormalFlag, "↑")
        // JSON 往返（Codable 全列）
        let decoded = try await exporter.decode(try await exporter.encode(envelope))
        XCTAssertEqual(decoded.hospitalizations, envelope.hospitalizations)
        XCTAssertEqual(decoded.labResults, envelope.labResults)
        // 全新库恢复：五表 + metric_sample 逐列相等，回执全部可校验
        let target = try GRDBStore.inMemory()
        try await ExportService(writer: target.writer).importJSON(decoded)
        for table in tables {
            let order = table == "ocr_card_commit" ? "card_id, row_id" : "id"
            let before = try await db.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM \(table) ORDER BY \(order)") }
            let after = try await target.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM \(table) ORDER BY \(order)") }
            XCTAssertEqual(after, before, table)
        }
        let restored = OCRCardStore(writer: target.writer)
        let labDetail = try await restored.detail(kind: "lab_report", entityId: try XCTUnwrap(envelope.labReports?.first?.id), patientId: patient)
        XCTAssertEqual(labDetail.labReport?.results.count, 2)
        XCTAssertEqual(labDetail.encounterIDs, [encounterId])
        let linked = try await EncounterStore(writer: target.writer).linkedCards(encounterId: encounterId, patientId: patient)
        XCTAssertEqual(Set(linked.map(\.kind)), [.hospitalization, .diagnosis, .examReport, .labReport])
        // 恢复库上再确认同一张检验卡：零写入（表头 / 行 / 回执一致）
        let replay = try await restored.save(card: lab, patientId: patient, documentId: document)
        XCTAssertEqual(replay.writtenCount, 0)
        // 同库再导入同一备份（冲突全部 adopt）：行随表头裁决、UNIQUE 不撞车、行数不翻倍
        let reimporter = ExportService(writer: target.writer)
        let conflicts = try await reimporter.conflictReport(decoded)
        XCTAssertTrue(conflicts.contains { $0.table == "lab_report" })
        XCTAssertTrue(conflicts.contains { $0.table == "diagnosis" })
        XCTAssertTrue(conflicts.contains { $0.table == "exam_report" })
        XCTAssertFalse(conflicts.contains { $0.table == "hospitalization" })          // 住院期随就诊裁决，不单列
        try await reimporter.importJSON(decoded, resolutions: Dictionary(conflicts.map { ($0.id, ExportService.ConflictResolution.adopt) }, uniquingKeysWith: { a, _ in a }))
        let counts9 = try await tableCounts(target, tables)
        XCTAssertEqual(counts9, [1, 1, 1, 1, 1, 2, 1, 6])
        // 并存：就诊/表头换 id → 住院期、定性行、回执随之换 id，UNIQUE(encounter_id)/UNIQUE(lab_report_id, ordinal) 不撞车
        let coexist = try await reimporter.conflictReport(decoded)
        try await reimporter.importJSON(decoded, resolutions: Dictionary(coexist.map { ($0.id, ExportService.ConflictResolution.coexist) }, uniquingKeysWith: { a, _ in a }))
        let counts10 = try await tableCounts(target, tables)
        XCTAssertEqual(counts10, [2, 2, 2, 2, 2, 4, 2, 12])
        let integrity = try await target.writer.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }
        XCTAssertTrue(integrity.isEmpty)
    }

    func test_backupRejectsCrossMemberOrDanglingClinicalRows() async throws {
        let (db, patient, document) = try await fixture()
        let other = UUID()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'B', 'other', 0, 0)", arguments: [other.uuidString])
        }
        let store = OCRCardStore(writer: db.writer)
        _ = try await store.save(card: hospitalizationCard(), patientId: patient, documentId: document)
        _ = try await store.save(card: labCard(pageIndex: 1), patientId: patient, documentId: document)
        let envelope = try await ExportService(writer: db.writer).exportJSON()
        var crossMember = envelope
        crossMember.hospitalizations?[0].patientId = other
        let target = try GRDBStore.inMemory()
        do {
            try await ExportService(writer: target.writer).importJSON(crossMember)
            XCTFail("A hospitalization owned by another member must not be restored under this encounter")
        } catch ExportService.ExportError.invalidOCRBackup {}
        var dangling = envelope
        dangling.labResults = []
        do {
            try await ExportService(writer: target.writer).importJSON(dangling)
            XCTFail("A lab_result receipt whose row is missing from the envelope must be rejected")
        } catch ExportService.ExportError.invalidOCRBackup {}
        var orphan = envelope
        orphan.labReports = []
        do {
            try await ExportService(writer: target.writer).importJSON(orphan)
            XCTFail("Rows pointing at a header missing from the envelope must be rejected")
        } catch ExportService.ExportError.invalidOCRBackup {}
        let counts11 = try await tableCounts(target, ["hospitalization", "lab_report", "lab_result", "metric_sample", "ocr_card_commit"])
        XCTAssertEqual(counts11, [0, 0, 0, 0, 0])
    }

    func test_legacyEnvelopeWithoutV26KeysStillRestores() async throws {
        let (db, patient, document) = try await fixture()
        _ = try await OCRCardStore(writer: db.writer).save(card: card(), patientId: patient, documentId: document)
        let exporter = ExportService(writer: db.writer)
        let current = try await exporter.exportJSON()
        XCTAssertEqual(current.labReports?.count, 1)
        let data = try await exporter.encode(current)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["hospitalizations", "diagnoses", "examReports", "labReports", "labResults"] { json[key] = nil }
        if var metrics = json["metrics"] as? [[String: Any]] {
            for index in metrics.indices { metrics[index]["labReportId"] = nil; metrics[index]["abnormalFlag"] = nil }
            json["metrics"] = metrics
        }
        let legacy = try await exporter.decode(try JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.labReports)
        XCTAssertNil(legacy.metrics.first?.labReportId)
        let target = try GRDBStore.inMemory()
        try await ExportService(writer: target.writer).importJSON(legacy)
        let counts12 = try await tableCounts(target, ["metric_sample", "lab_report", "lab_result", "ocr_card_commit"])
        XCTAssertEqual(counts12, [2, 0, 0, 2])
        let orphaned = try await target.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample WHERE lab_report_id IS NULL") }
        XCTAssertEqual(orphaned, 2)   // 无表头的历史行照常恢复、逐行可达
        let cards = try await OCRCardStore(writer: target.writer).cards(documentId: document, patientId: patient)
        XCTAssertEqual(cards.map { $0.kind }, ["metric_sample", "metric_sample"])
    }

    // MARK: - v27 card-hierarchy（子项目 J · J3）：主卡草稿同事务、体检 / 结论 / 手术 / 治疗落库、预约 / 提醒挂接、五数组备份

    private func confirmedDraft(_ draft: HubDraft) -> HubDraft {
        var copy = draft
        for i in copy.fields.indices { _ = copy.fields[i].confirm() }
        return copy
    }

    private func healthExamCard(pageIndex: Int = 0) -> MatchedCard {
        MatchedCard(kind: "health_exam", pageIndex: pageIndex, shared: [
            .init(key: "org_name", value: "美年体检"), .init(key: "exam_date", value: "2024-05-06"),
            .init(key: "height", value: "170", unit: "cm"), .init(key: "weight", value: "65.5", unit: "kg"),
            .init(key: "systolic", value: "128", unit: "mmHg"), .init(key: "vision_left", value: "1.0"),
            .init(key: "overall_conclusion", value: "总检：血脂偏高，建议复查")],
            rows: [MatchedCardRow(fields: [])], allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
    }

    private func conclusionCard(pageIndex: Int = 1, association: EncounterAssociation = .unselected) -> MatchedCard {
        MatchedCard(kind: "clinical_conclusion", pageIndex: pageIndex,
            shared: [.init(key: "org_name", value: "美年体检"), .init(key: "exam_date", value: "2024-05-06")],
            rows: [MatchedCardRow(fields: [.init(key: "content", value: "血脂偏高"), .init(key: "severity", value: "关注")]),
                   MatchedCardRow(fields: [.init(key: "content", value: "三个月后复查血脂"), .init(key: "conclusion_type", value: "recheck_advice")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete, encounterAssociation: association).fullyConfirmed()
    }

    /// §0.4 改判 / round1 V7：无 ±3 日同医院就诊 → 主卡草稿与处方同事务落库并关联；重放不重复建卡。
    func test_prescriptionWithNewHubDraftCreatesEncounterInSameTransaction() async throws {
        let (db, patient, document) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        var card = prescriptionCard(shared: [.init(key: "prescribed_at", value: "2024-03-01"), .init(key: "hospital", value: "市一院")],
                                    rows: [[.init(key: "drug_name", value: "阿莫西林")]])
        let draft = confirmedDraft(try XCTUnwrap(ParentCardDraftRules.deriveHub(from: card, documentTypeKey: "prescription")))
        XCTAssertEqual(draft.hub, .encounter)
        card.encounterAssociation = .newHub(draft)
        let result = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(result.writtenCount, 1)
        XCTAssertTrue(result.resolved)
        let encounterCounts = try await tableCounts(db, ["encounter", "prescription", "prescription_line", "ocr_card_commit"])
        XCTAssertEqual(encounterCounts, [1, 1, 1, 1])
        let row = try await db.writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT e.id AS eid, e.hospital, e.kind, e.date, e.patient_id, p.encounter_id, c.encounter_id AS receipt, c.entity_table
                FROM encounter e JOIN prescription p ON p.encounter_id = e.id
                JOIN prescription_line l ON l.prescription_id = p.id JOIN ocr_card_commit c ON c.entity_id = l.id
                """)
        }
        let joined = try XCTUnwrap(row)
        XCTAssertEqual(joined["hospital"] as String?, "市一院")
        XCTAssertEqual(joined["kind"] as String?, EncounterKind.outpatient.rawValue)              // 文档键无提示 → 门诊
        XCTAssertEqual(joined["patient_id"] as String?, patient.uuidString)
        XCTAssertEqual(joined["date"] as Double?, EntityCardProjection.parseDate("2024-03-01", calendar: Calendar(identifier: .gregorian))?.timeIntervalSince1970)
        XCTAssertEqual(joined["encounter_id"] as String?, joined["receipt"] as String?, "子卡 FK 与回执 encounter_id 同值")
        XCTAssertEqual(joined["entity_table"] as String?, "prescription_line")                    // 主卡不另立回执（注册表约束）
        let created = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM audit_event WHERE action = 'create' AND entity_type = 'encounter'") }
        XCTAssertEqual(created, 1)                                                                 // 主卡来源留痕 = audit_event
        // pending 快照已归一化为 .existing(新就诊)
        let encounterId = try XCTUnwrap(UUID(uuidString: joined["eid"] as String))
        let state = try await store.reviewState(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(state.card.encounterAssociation, .existing(encounterId))
        // 用 UI 仍持有的 .newHub 重放 → 零写入、不再建就诊、不报 committedDataChanged
        let replay = try await store.save(card: card, patientId: patient, documentId: document, pendingCardId: result.pendingCardId)
        XCTAssertEqual(replay.writtenCount, 0)
        let replayCounts = try await tableCounts(db, ["encounter", "prescription_line"])
        XCTAssertEqual(replayCounts, [1, 1])
        // 时间轴：主卡 + 处方子卡（原件经回执关系亦收为子卡，不再是叶子）
        let page = try await TimelineQueryStore(writer: db.writer).hubPage(patientId: patient)
        XCTAssertEqual(page.entries.map(\.hub), [.encounter])
        XCTAssertEqual(Set(page.entries[0].children.map(\.kind)), [.prescription, .document])
        let linked = try await EncounterStore(writer: db.writer).linkedCards(encounterId: encounterId, patientId: patient)
        XCTAssertEqual(linked.map(\.kind), [.prescription])
    }

    /// round1 V8/V9：草稿字段未确认 → invalidCard 零写入；证据过期（改了医院未重派生）→ invalidAssociation。
    func test_newHubDraftRefusedWhenFieldsUnconfirmedOrEvidenceStale() async throws {
        let (db, patient, document) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        var card = prescriptionCard(shared: [.init(key: "prescribed_at", value: "2024-03-01"), .init(key: "hospital", value: "市一院")],
                                    rows: [[.init(key: "drug_name", value: "阿莫西林")]])
        card.encounterAssociation = .newHub(try XCTUnwrap(ParentCardDraftRules.deriveHub(from: card, documentTypeKey: nil)))   // 草稿字段未确认（D 级）
        do { _ = try await store.save(card: card, patientId: patient, documentId: document); XCTFail("草稿未确认必须拒绝") }
        catch OCRCardStore.StoreError.invalidCard {}
        let unconfirmedCounts = try await tableCounts(db, ["encounter", "prescription", "ocr_card_commit"])
        XCTAssertEqual(unconfirmedCounts, [0, 0, 0], "BR-003：零写入")
        var stale = confirmedDraft(try XCTUnwrap(ParentCardDraftRules.deriveHub(from: card, documentTypeKey: nil)))
        stale.evidence = "hospital=别的医院"                                                        // 证据过期（用户改了子卡医院字段后未重派生）
        card.encounterAssociation = .newHub(stale)
        do { _ = try await store.save(card: card, patientId: patient, documentId: document); XCTFail("证据过期必须拒绝") }
        catch OCRCardStore.StoreError.invalidAssociation {}
        let staleEvidenceCounts = try await tableCounts(db, ["encounter", "prescription"])
        XCTAssertEqual(staleEvidenceCounts, [0, 0])
        // 住院期不经草稿：草稿枢纽 hospitalization → invalidCard
        var stay = confirmedDraft(try XCTUnwrap(ParentCardDraftRules.deriveHub(from: card, documentTypeKey: nil)))
        stay.hub = .hospitalization
        card.encounterAssociation = .newHub(stay)
        do { _ = try await store.save(card: card, patientId: patient, documentId: document); XCTFail("住院期草稿必须拒绝") }
        catch OCRCardStore.StoreError.invalidCard {}
    }

    /// round1 V10：体检首页卡 → health_exam 1 行 + 体重/收缩压投影、身高（无键）/视力（无单位键）不投影、原文列保留。
    func test_healthExamCardProjectsOnlyKeyedStrictNumbers() async throws {
        let (db, patient, document) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        let card = healthExamCard()
        let result = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(result.writtenCount, 1)
        let projectedCounts = try await tableCounts(db, ["health_exam", "metric_sample", "ocr_card_commit"])
        XCTAssertEqual(projectedCounts, [1, 2, 1])
        let examRow = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT * FROM health_exam") }
        let exam = try XCTUnwrap(examRow)
        XCTAssertEqual(exam["height_text"] as String?, "170")                                      // 原文保留，不投影
        XCTAssertEqual(exam["weight_text"] as String?, "65.5")
        XCTAssertEqual(exam["vision_left_text"] as String?, "1.0")
        XCTAssertEqual(exam["confirmed"] as Int?, 1)
        XCTAssertEqual(exam["source"] as String?, "ocr")
        XCTAssertEqual(exam["document_file_id"] as String?, document.uuidString)
        let examId = try XCTUnwrap(UUID(uuidString: exam["id"] as String))
        XCTAssertEqual(examId, card.rows[0].id)                                                     // id = 回执 row_id（确定性）
        let samples = try await db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT metric_key, value, unit, origin, ref_source_label, lab_report_id FROM metric_sample WHERE health_exam_id = ? ORDER BY metric_key",
                             arguments: [examId.uuidString])
        }
        XCTAssertEqual(samples.map { $0["metric_key"] as String }, ["bloodPressureSys", "weight"])
        XCTAssertEqual(samples.map { $0["value"] as Double }, [128, 65.5])
        XCTAssertEqual(samples.map { $0["unit"] as String }, ["mmHg", "kg"])
        XCTAssertEqual(Set(samples.map { $0["origin"] as String }), ["hospital"])
        XCTAssertEqual(Set(samples.map { $0["ref_source_label"] as String? }), ["美年体检"])
        XCTAssertTrue(samples.allSatisfy { ($0["lab_report_id"] as String?) == nil })
        let receiptRow = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT entity_table, entity_id FROM ocr_card_commit") }
        let receipt = try XCTUnwrap(receiptRow)
        XCTAssertEqual(receipt["entity_table"] as String?, "health_exam")                          // 投影点无回执
        XCTAssertEqual(receipt["entity_id"] as String?, examId.uuidString)
        let detail = try await HealthExamStore(writer: db.writer).detail(id: examId, patientId: patient)
        XCTAssertEqual(detail.exam.orgName, "美年体检")
        XCTAssertEqual(detail.generalSamples.count, 2)
        XCTAssertEqual(detail.documentId, document)
        XCTAssertTrue(detail.reports.isEmpty)
        let cardDetail = try await store.detail(kind: "health_exam", entityId: examId, patientId: patient)
        XCTAssertEqual(cardDetail.fields.first { $0.key == "height" }?.value, "170")
        XCTAssertEqual(cardDetail.fields.first { $0.key == "exam_date" }?.value, "2024-05-06")
        XCTAssertFalse(cardDetail.relationshipEditable)                                             // 体检是枢纽自身，不改挂就诊
        XCTAssertEqual(cardDetail.healthExam?.id, examId)
        do { _ = try await HealthExamStore(writer: db.writer).detail(id: examId, patientId: UUID()); XCTFail("跨成员必须拒绝") }
        catch OCRCardStore.StoreError.invalidCard {}
        // 幂等：同卡再确认零写入、不重复投影
        let replay = try await store.save(card: card, patientId: patient, documentId: document, pendingCardId: result.pendingCardId)
        XCTAssertEqual(replay.writtenCount, 0)
        let examCounts = try await tableCounts(db, ["health_exam", "metric_sample"])
        XCTAssertEqual(examCounts, [1, 2])
        // 时间轴：体检主卡 + 原件子卡
        let page = try await TimelineQueryStore(writer: db.writer).hubPage(patientId: patient)
        XCTAssertEqual(page.entries.map(\.hub), [.healthExam])
        XCTAssertEqual(page.entries[0].children.map(\.kind), [.document])
    }

    /// 结论卡：体检草稿同事务建枢纽、恰一父 = 体检；同文档首页卡随后会合到同一体检行；跨成员体检 / 无父 → 拒绝。
    func test_clinicalConclusionCardUsesHealthExamDraftAsExactlyOneParent() async throws {
        let (db, patient, document) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        var card = conclusionCard()
        let draft = confirmedDraft(try XCTUnwrap(ParentCardDraftRules.deriveHub(from: card, documentTypeKey: "checkup_report")))
        XCTAssertEqual(draft.hub, .healthExam)
        card.encounterAssociation = .newHub(draft)
        let result = try await store.save(card: card, patientId: patient, documentId: document)
        XCTAssertEqual(result.writtenCount, 2)
        let hubCounts = try await tableCounts(db, ["health_exam", "clinical_conclusion", "ocr_card_commit"])
        XCTAssertEqual(hubCounts, [1, 2, 2])
        let rows = try await db.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM clinical_conclusion ORDER BY ordinal") }
        XCTAssertEqual(rows.map { $0["content"] as String }, ["血脂偏高", "三个月后复查血脂"])
        XCTAssertEqual(rows.map { $0["severity_text"] as String? }, ["关注", nil])                 // 打印原文，不编码（BR-004/012）
        XCTAssertEqual(rows.map { $0["conclusion_type"] as String }, ["abnormal_finding", "recheck_advice"])   // 关键词 D 级默认 / 行覆盖
        XCTAssertEqual(rows.map { $0["ordinal"] as Int }, [0, 1])
        XCTAssertTrue(rows.allSatisfy { ($0["health_exam_id"] as String?) != nil && ($0["lab_report_id"] as String?) == nil && ($0["exam_report_id"] as String?) == nil })
        XCTAssertEqual(rows.map { $0["id"] as String }, card.rows.map(\.id.uuidString))            // id = 回执 row_id
        let examRow = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT * FROM health_exam") }
        let exam = try XCTUnwrap(examRow)
        XCTAssertEqual(exam["org_name"] as String?, "美年体检"); XCTAssertEqual(exam["confirmed"] as Int?, 1)
        XCTAssertNil(exam["weight_text"] as String?)
        let examId = try XCTUnwrap(UUID(uuidString: exam["id"] as String))
        let reviewedAssociation = try await store.reviewState(card: card, patientId: patient, documentId: document).card.encounterAssociation
        XCTAssertEqual(reviewedAssociation, .existingHub(.healthExam, examId))
        let receiptTables = Set(try await db.writer.read { try String.fetchAll($0, sql: "SELECT entity_table FROM ocr_card_commit") })
        XCTAssertEqual(receiptTables, ["clinical_conclusion"])
        // 同文档首页卡随后确认：会合到同一体检行（幂等键 = 同文档），只补空、投影一般检查
        _ = try await store.save(card: healthExamCard(pageIndex: 0), patientId: patient, documentId: document)
        let mergedCounts = try await tableCounts(db, ["health_exam", "metric_sample", "clinical_conclusion", "ocr_card_commit"])
        XCTAssertEqual(mergedCounts, [1, 2, 2, 3])
        let mergedExam = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT id, weight_text, overall_conclusion FROM health_exam") }
        let merged = try XCTUnwrap(mergedExam)
        XCTAssertEqual(merged["id"] as String?, examId.uuidString)
        XCTAssertEqual(merged["weight_text"] as String?, "65.5")
        XCTAssertEqual(merged["overall_conclusion"] as String?, "总检：血脂偏高，建议复查")
        let detail = try await HealthExamStore(writer: db.writer).detail(id: examId, patientId: patient)
        XCTAssertEqual(detail.conclusions.map(\.content), ["血脂偏高", "三个月后复查血脂"])
        XCTAssertEqual(detail.generalSamples.count, 2)
        let conclusionCount = try await HealthExamStore(writer: db.writer).children(ofHealthExam: examId, patientId: patient).conclusions.count
        XCTAssertEqual(conclusionCount, 2)
        let conclusionDetail = try await store.detail(kind: "clinical_conclusion", entityId: card.rows[0].id, patientId: patient)
        XCTAssertEqual(conclusionDetail.clinicalConclusions.count, 2)
        XCTAssertEqual(conclusionDetail.fields.first { $0.key == "severity" }?.value, "关注")
        XCTAssertFalse(conclusionDetail.relationshipEditable)
        // 用 UI 仍持有的 .newHub 重放 → 零写入、不再建体检
        let replay = try await store.save(card: card, patientId: patient, documentId: document, pendingCardId: result.pendingCardId)
        XCTAssertEqual(replay.writtenCount, 0)
        let healthExamCounts = try await tableCounts(db, ["health_exam"])
        XCTAssertEqual(healthExamCounts, [1])
        // 跨成员体检枢纽 → invalidAssociation 零写入；无枢纽且同文档无唯一报告 → invalidCard
        let other = UUID(), foreignExam = UUID()
        try await db.writer.write { d in
            try d.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'B', 'other', 0, 0)", arguments: [other.uuidString])
            try d.execute(sql: "INSERT INTO health_exam (id, patient_id, org_name, exam_date, source, confirmed, created_at, updated_at) VALUES (?, ?, 'X', 0, 'manual', 1, 0, 0)",
                          arguments: [foreignExam.uuidString, other.uuidString])
        }
        let secondDocument = try await fixtureDocument(db, patient: patient)
        do { _ = try await store.save(card: conclusionCard(pageIndex: 0, association: .existingHub(.healthExam, foreignExam)), patientId: patient, documentId: secondDocument); XCTFail("跨成员体检必须拒绝") }
        catch OCRCardStore.StoreError.invalidAssociation {}
        do { _ = try await store.save(card: conclusionCard(pageIndex: 0, association: .none), patientId: patient, documentId: secondDocument); XCTFail("无父必须拒绝") }
        catch OCRCardStore.StoreError.invalidCard {}
        let conclusionCounts = try await tableCounts(db, ["clinical_conclusion"])
        XCTAssertEqual(conclusionCounts, [2])
    }

    private func fixtureDocument(_ db: GRDBStore, patient: UUID) async throws -> UUID {
        try await DocumentStore(writer: db.writer).save(
            patientId: patient, docType: "checkup_report", sha256: "ocr-test-2", mimeType: "image/png",
            origin: "import", isSensitive: false, metaJSON: nil, title: "Second", grade: "C",
            pages: [.init(index: 0, text: "Page")])
    }

    /// 手术 / 治疗卡：显式归属就诊、原文列、无双计（治疗药物不进 prescription_line）；就诊关联卡追加两源；可改挂。
    func test_surgeryAndTreatmentCardsLinkToEncounterAndAppearInLinkedCards() async throws {
        let (db, patient, document) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        let enc = try await EncounterStore(writer: db.writer).upsert(encounter: .init(patientId: patient, date: Date(timeIntervalSince1970: 1_700_000_000), kind: "inpatient"))
        let surgery = singleRowCard(kind: "surgery", pageIndex: 0, shared: [
            .init(key: "surgery_at", value: "2024-03-02"), .init(key: "surgery_name", value: "腹腔镜胆囊切除术"), .init(key: "surgeon", value: "王医生"),
            .init(key: "surgery_level", value: "三级"), .init(key: "implants", value: "钛夹 3 枚"), .init(key: "blood_loss", value: "约 20ml")], encounter: enc)
        let saved = try await store.save(card: surgery, patientId: patient, documentId: document)
        XCTAssertEqual(saved.writtenCount, 1)
        let surgeryRow = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT s.*, c.entity_table FROM surgery s JOIN ocr_card_commit c ON c.entity_id = s.id") }
        let s = try XCTUnwrap(surgeryRow)
        XCTAssertEqual(s["encounter_id"] as String?, enc.uuidString)
        XCTAssertEqual(s["surgery_level_text"] as String?, "三级")                                 // 只存打印文本
        XCTAssertEqual(s["implants_text"] as String?, "钛夹 3 枚")
        XCTAssertEqual(s["blood_loss_text"] as String?, "约 20ml")
        XCTAssertEqual(s["confirmed"] as Int?, 1); XCTAssertEqual(s["entity_table"] as String?, "surgery")
        let treatment = singleRowCard(kind: "treatment_record", pageIndex: 1, shared: [
            .init(key: "treated_at", value: "2024-03-03"), .init(key: "treatment_type", value: "infusion"),
            .init(key: "drugs_text", value: "头孢曲松 2g ivgtt qd"), .init(key: "adverse_reaction", value: "无")], encounter: enc)
        _ = try await store.save(card: treatment, patientId: patient, documentId: document)
        let treatmentCounts = try await tableCounts(db, ["surgery", "treatment_record", "prescription_line", "medication", "ocr_card_commit"])
        XCTAssertEqual(treatmentCounts, [1, 1, 0, 0, 2])
        let treatmentRow = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT * FROM treatment_record") }
        let t = try XCTUnwrap(treatmentRow)
        XCTAssertEqual(t["drugs_text"] as String?, "头孢曲松 2g ivgtt qd")                          // 原文不拆行（BR-006/007）
        XCTAssertEqual(t["adverse_reaction_text"] as String?, "无")
        let linked = try await EncounterStore(writer: db.writer).linkedCards(encounterId: enc, patientId: patient)
        XCTAssertEqual(Set(linked.map(\.kind)), [.surgery, .treatmentRecord])
        XCTAssertEqual(linked.first { $0.kind == .treatmentRecord }?.kind.cardKind, "treatment_record")
        let surgeryId = try XCTUnwrap(UUID(uuidString: s["id"] as String))
        let detail = try await store.detail(kind: "surgery", entityId: surgeryId, patientId: patient)
        XCTAssertEqual(detail.fields.first { $0.key == "implants" }?.value, "钛夹 3 枚")
        XCTAssertEqual(detail.fields.first { $0.key == "surgery_at" }?.value, "2024-03-02")
        XCTAssertEqual(detail.surgery?.surgeryName, "腹腔镜胆囊切除术")
        XCTAssertEqual(detail.encounterIDs, [enc]); XCTAssertTrue(detail.relationshipEditable)
        try await store.associate(kind: "surgery", entityId: surgeryId, patientId: patient, encounterId: nil)
        let linkedKinds = try await EncounterStore(writer: db.writer).linkedCards(encounterId: enc, patientId: patient).map(\.kind)
        XCTAssertEqual(linkedKinds, [.treatmentRecord])
        // 解除归属后的手术在时间轴成为无父叶子（2024-03-02，晚于就诊日）；治疗仍在就诊主卡下；原件经治疗回执收为子卡
        let page = try await TimelineQueryStore(writer: db.writer).hubPage(patientId: patient)
        XCTAssertEqual(page.entries.map(\.hub), [nil, .encounter])
        XCTAssertEqual(page.entries[0].entry.kind, .surgery)
        XCTAssertEqual(Set(page.entries[1].children.map(\.kind)), [.treatmentRecord, .document])
        // 跨成员就诊 → 整卡回滚
        let other = UUID()
        try await db.writer.write { try $0.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'B', 'other', 0, 0)", arguments: [other.uuidString]) }
        let foreign = try await EncounterStore(writer: db.writer).upsert(encounter: .init(patientId: other, date: Date(), kind: "outpatient"))
        let secondDocument = try await fixtureDocument(db, patient: patient)
        do { _ = try await store.save(card: singleRowCard(kind: "surgery", pageIndex: 0, shared: [.init(key: "surgery_at", value: "2024-03-02"), .init(key: "surgery_name", value: "X")], encounter: foreign),
                                      patientId: patient, documentId: secondDocument); XCTFail("跨成员就诊必须拒绝") }
        catch OCRCardStore.StoreError.invalidAssociation {}
        let surgeryCounts = try await tableCounts(db, ["surgery"])
        XCTAssertEqual(surgeryCounts, [1])
    }

    /// FR10.7 / FR8.10：复诊预约与随访提醒挂就诊；显式 link / candidates；白名单外来源与零行更新必须抛错。
    func test_followUpAppointmentAndReminderAppearUnderEncounter() async throws {
        let (db, patient, _) = try await fixture()
        let visit = Date(timeIntervalSince1970: 1_700_000_000)
        let enc = try await EncounterStore(writer: db.writer).upsert(encounter: .init(patientId: patient, date: visit, kind: "outpatient", hospital: "市一院"))
        let apts = AppointmentStore(writer: db.writer, scheduler: InMemoryReminderScheduler())
        let reminders = ReminderLinkStore(writer: db.writer)
        let apt = try await apts.create(patientId: patient, hospital: "市一院", department: "呼吸内科", startsAt: visit.addingTimeInterval(86_400 * 14),
                                        encounterId: enc, purpose: .followUp)
        let rem = try await reminders.create(patientId: patient, kind: "followUp", title: "两周后复诊", at: visit.addingTimeInterval(86_400 * 13),
                                             source: .init(table: "appointment", id: apt))
        let linked = try await EncounterStore(writer: db.writer).linkedCards(encounterId: enc, patientId: patient)
        XCTAssertEqual(Set(linked.map(\.kind)), [.appointment, .reminder])
        XCTAssertEqual(linked.first { $0.kind == .appointment }?.summary, "市一院 · 呼吸内科")
        let linkedReminderIds = try await reminders.linked(source: .init(table: "appointment", id: apt), patientId: patient).map(\.id)
        XCTAssertEqual(linkedReminderIds, [rem])
        let crossMemberLinkedEmpty = try await reminders.linked(source: .init(table: "appointment", id: apt), patientId: UUID()).isEmpty
        XCTAssertTrue(crossMemberLinkedEmpty, "BR-001")
        // 白名单外来源 / 他人的来源 → invalidSource 零写入
        do { _ = try await reminders.create(patientId: patient, kind: "followUp", title: "x", at: Date(), source: .init(table: "medication_plan", id: rem)); XCTFail("白名单外来源必须拒绝") }
        catch ReminderLinkStore.Error.invalidSource {}
        do { _ = try await reminders.create(patientId: UUID(), kind: "followUp", title: "x", at: Date(), source: .init(table: "encounter", id: enc)); XCTFail("他人的来源必须拒绝") }
        catch ReminderLinkStore.Error.invalidSource {}
        let reminderCounts = try await tableCounts(db, ["reminder"])
        XCTAssertEqual(reminderCounts, [1])
        // 时间轴：预约 / 提醒为就诊子卡（提醒经预约到达）；无回执的原件仍是叶子（创建于今日，排在 2023 年的就诊之前）
        let page = try await TimelineQueryStore(writer: db.writer).hubPage(patientId: patient)
        XCTAssertEqual(page.entries.map(\.hub), [nil, .encounter])
        XCTAssertEqual(page.entries[0].entry.kind, .document)
        XCTAssertEqual(page.entries[1].children.map(\.kind), [.appointment, .reminder])
        // 显式挂接：候选 = 同成员、未挂接、±3 日、同医院；零行 / 跨成员抛错
        let loose = try await apts.create(patientId: patient, hospital: "市一院", department: "呼吸内科", startsAt: visit.addingTimeInterval(86_400))
        _ = try await apts.create(patientId: patient, hospital: "别院", department: "内科", startsAt: visit.addingTimeInterval(86_400))
        _ = try await apts.create(patientId: patient, hospital: "市一院", department: "内科", startsAt: visit.addingTimeInterval(86_400 * 10))
        let candidateIds = try await apts.candidates(forEncounter: enc, patientId: patient).map(\.id)
        XCTAssertEqual(candidateIds, [loose])
        do { try await apts.link(appointmentId: UUID(), encounterId: enc, patientId: patient); XCTFail("零行更新必须抛错") }
        catch AppointmentStore.StoreError.notFound {}
        do { try await apts.link(appointmentId: loose, encounterId: UUID(), patientId: patient); XCTFail("就诊不存在必须抛错") }
        catch AppointmentStore.StoreError.invalidEncounter {}
        try await apts.link(appointmentId: loose, encounterId: enc, patientId: patient)
        let candidatesEmpty = try await apts.candidates(forEncounter: enc, patientId: patient).isEmpty
        XCTAssertTrue(candidatesEmpty)
        let rows = try await apts.history(patientId: patient)
        XCTAssertEqual(rows.first { $0.id == loose }?.encounterId, enc)
        XCTAssertEqual(rows.first { $0.id == loose }?.purpose, "visit")                            // 缺省 visit
        XCTAssertEqual(rows.first { $0.id == apt }?.purpose, "followUp")
        try await apts.unlink(appointmentId: loose, patientId: patient)
        let unlinkedEncounterId = try await apts.history(patientId: patient).first { $0.id == loose }?.encounterId
        XCTAssertNil(unlinkedEncounterId)
        // 「已完成 → 补录就诊」回写 encounter_id
        try await apts.complete(id: loose)
        let completedRow = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT a.encounter_id, e.hospital FROM appointment a JOIN encounter e ON e.id = a.encounter_id WHERE a.id = ?", arguments: [loose.uuidString]) }
        let completed = try XCTUnwrap(completedRow)
        XCTAssertEqual(completed["hospital"] as String?, "市一院")
    }

    /// FR13.2/13.5：五数组 + 新列备份往返、同库再导入（adopt 不翻倍 / coexist 随父换 id、FK 完整）、旧包（无 v27 键）照常恢复。
    func test_cardHierarchyRoundTripsThroughBackupAndLegacyEnvelopeStillRestores() async throws {
        let (db, patient, document) = try await fixture()
        let store = OCRCardStore(writer: db.writer)
        _ = try await store.save(card: healthExamCard(pageIndex: 0), patientId: patient, documentId: document)
        let examIdText = try await db.writer.read { try String.fetchOne($0, sql: "SELECT id FROM health_exam") }
        let examId = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(examIdText)))
        _ = try await store.save(card: conclusionCard(pageIndex: 1, association: .existingHub(.healthExam, examId)), patientId: patient, documentId: document)
        // 体检文档上的检验卡挂体检枢纽：表头 report_source = health_exam、health_exam_id；数值行回指体检
        _ = try await store.save(card: {
            var lab = labCard(pageIndex: 1); lab.encounterAssociation = .existingHub(.healthExam, examId); return lab
        }(), patientId: patient, documentId: document)
        var surgery = singleRowCard(kind: "surgery", pageIndex: 0, shared: [.init(key: "surgery_at", value: "2024-03-02"), .init(key: "surgery_name", value: "阑尾切除术"), .init(key: "hospital", value: "市一院")])
        surgery.encounterAssociation = .newHub(confirmedDraft(try XCTUnwrap(ParentCardDraftRules.deriveHub(from: surgery, documentTypeKey: "surgery_record"))))
        _ = try await store.save(card: surgery, patientId: patient, documentId: document)
        let encounterIdText = try await db.writer.read { try String.fetchOne($0, sql: "SELECT id FROM encounter") }
        let enc = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(encounterIdText)))
        _ = try await store.save(card: singleRowCard(kind: "treatment_record", pageIndex: 1, shared: [
            .init(key: "treated_at", value: "2024-03-03"), .init(key: "treatment_type", value: "dressing"), .init(key: "content", value: "换药一次")], encounter: enc),
            patientId: patient, documentId: document)
        let apts = AppointmentStore(writer: db.writer, scheduler: InMemoryReminderScheduler())
        _ = try await apts.create(patientId: patient, hospital: "市一院", department: "外科", startsAt: Date(timeIntervalSince1970: 1_720_000_000), encounterId: enc, purpose: .followUp)
        _ = try await ReminderLinkStore(writer: db.writer).create(patientId: patient, kind: "followUp", title: "拆线", at: Date(timeIntervalSince1970: 1_719_000_000), source: .init(table: "encounter", id: enc))
        let tables = ["encounter", "health_exam", "clinical_conclusion", "surgery", "treatment_record", "lab_report", "lab_result", "metric_sample", "appointment", "reminder", "ocr_card_commit"]
        let before = try await tableCounts(db, tables)
        XCTAssertEqual(before, [1, 1, 2, 1, 1, 1, 2, 3, 1, 1, 8])
        let exporter = ExportService(writer: db.writer)
        let envelope = try await exporter.exportJSON()
        XCTAssertEqual(envelope.schemaVersion, 2)                                                   // 只增可选键，版本不变
        XCTAssertEqual(envelope.healthExams?.map(\.id), [examId])
        XCTAssertEqual(envelope.clinicalConclusions?.count, 2)
        XCTAssertEqual(envelope.clinicalConclusions?.map(\.healthExamId), [examId, examId])
        XCTAssertEqual(envelope.surgeries?.map(\.encounterId), [enc])
        XCTAssertEqual(envelope.treatmentRecords?.map(\.treatmentType), ["dressing"])
        XCTAssertEqual(envelope.reminders?.map(\.sourceTable), ["encounter"])
        XCTAssertEqual(envelope.reminders?.first?.sourceId, enc)
        XCTAssertEqual(envelope.appointments.first?.encounterId, enc)
        XCTAssertEqual(envelope.appointments.first?.purpose, "followUp")
        XCTAssertEqual(envelope.labReports?.first?.reportSource, "health_exam")
        XCTAssertEqual(envelope.labReports?.first?.healthExamId, examId)
        XCTAssertEqual(Set(envelope.metrics.map(\.healthExamId)), [examId])                          // 投影点 + 挂体检的检验数值行
        let decoded = try await exporter.decode(try await exporter.encode(envelope))
        XCTAssertEqual(decoded.healthExams, envelope.healthExams)
        XCTAssertEqual(decoded.clinicalConclusions, envelope.clinicalConclusions)
        XCTAssertEqual(decoded.surgeries, envelope.surgeries)
        XCTAssertEqual(decoded.treatmentRecords, envelope.treatmentRecords)
        XCTAssertEqual(decoded.reminders, envelope.reminders)
        XCTAssertEqual(decoded.appointments, envelope.appointments)
        // 全新库恢复：逐表逐列相等，回执全部可校验
        let target = try GRDBStore.inMemory()
        try await ExportService(writer: target.writer).importJSON(decoded)
        for table in tables {
            let order = table == "ocr_card_commit" ? "card_id, row_id" : "id"
            let source = try await db.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM \(table) ORDER BY \(order)") }
            let restored = try await target.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM \(table) ORDER BY \(order)") }
            XCTAssertEqual(restored, source, table)
        }
        let restoredDetail = try await HealthExamStore(writer: target.writer).detail(id: examId, patientId: patient)
        XCTAssertEqual(restoredDetail.conclusions.count, 2)
        XCTAssertEqual(restoredDetail.reports.map(\.reportType), [.lab])
        XCTAssertEqual(restoredDetail.reports.first?.reportSource, .healthExam)
        XCTAssertEqual(restoredDetail.generalSamples.count, 2)
        let restoredLinked = try await EncounterStore(writer: target.writer).linkedCards(encounterId: enc, patientId: patient)
        XCTAssertEqual(Set(restoredLinked.map(\.kind)), [.surgery, .treatmentRecord, .appointment, .reminder])
        // 同库再导入（全部 adopt）：独立冲突表含 health_exam / surgery / treatment_record / reminder，结论随父，不翻倍
        let reimporter = ExportService(writer: target.writer)
        let conflicts = try await reimporter.conflictReport(decoded)
        for table in ["health_exam", "surgery", "treatment_record", "reminder", "appointment", "lab_report"] {
            XCTAssertTrue(conflicts.contains { $0.table == table }, table)
        }
        XCTAssertFalse(conflicts.contains { $0.table == "clinical_conclusion" })
        try await reimporter.importJSON(decoded, resolutions: Dictionary(conflicts.map { ($0.id, ExportService.ConflictResolution.adopt) }, uniquingKeysWith: { a, _ in a }))
        let adoptCounts = try await tableCounts(target, tables)
        XCTAssertEqual(adoptCounts, before)
        // 并存：体检 / 就诊 / 预约换 id → 结论 / 表头 / 提醒来源 / 回执随之换 id，FK 完整
        let coexist = try await reimporter.conflictReport(decoded)
        try await reimporter.importJSON(decoded, resolutions: Dictionary(coexist.map { ($0.id, ExportService.ConflictResolution.coexist) }, uniquingKeysWith: { a, _ in a }))
        let coexistCounts = try await tableCounts(target, tables)
        XCTAssertEqual(coexistCounts, before.map { $0 * 2 })
        let foreignKeysClean = try await target.writer.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty
        XCTAssertTrue(foreignKeysClean)
        let orphanConclusions = try await target.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM clinical_conclusion c WHERE NOT EXISTS (SELECT 1 FROM health_exam h WHERE h.id = c.health_exam_id AND h.patient_id = c.patient_id)") }
        XCTAssertEqual(orphanConclusions, 0)
        let danglingReminders = try await target.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM reminder r WHERE r.source_table = 'encounter' AND NOT EXISTS (SELECT 1 FROM encounter e WHERE e.id = r.source_id)") }
        XCTAssertEqual(danglingReminders, 0)
        // 备份拒收：结论无父 / 跨成员体检回指
        var noParent = decoded
        noParent.clinicalConclusions?[0].healthExamId = nil
        do { try await ExportService(writer: GRDBStore.inMemory().writer).importJSON(noParent); XCTFail("结论恰一父缺失必须拒收") }
        catch ExportService.ExportError.invalidOCRBackup {}
        var crossMember = decoded
        crossMember.healthExams?[0].patientId = UUID()
        do { try await ExportService(writer: GRDBStore.inMemory().writer).importJSON(crossMember); XCTFail("跨成员体检回指必须拒收") }
        catch ExportService.ExportError.invalidOCRBackup {}
        // 旧包（无 v27 键）：只含就诊 + 预约 + 检验卡的包去掉五数组键与三列 → 照常恢复，新列为 NULL
        let legacyDb = try GRDBStore.inMemory()
        let legacyPatient = UUID()
        try await legacyDb.writer.write { try $0.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'L', 'other', 0, 0)", arguments: [legacyPatient.uuidString]) }
        let legacyDocument = try await fixtureDocument(legacyDb, patient: legacyPatient)
        let legacyEncounter = try await EncounterStore(writer: legacyDb.writer).upsert(encounter: .init(patientId: legacyPatient, date: Date(timeIntervalSince1970: 1_700_000_000), kind: "outpatient"))
        _ = try await AppointmentStore(writer: legacyDb.writer, scheduler: InMemoryReminderScheduler()).create(patientId: legacyPatient, hospital: "A", department: "B", startsAt: Date(timeIntervalSince1970: 1_701_000_000), encounterId: legacyEncounter, purpose: .followUp)
        _ = try await OCRCardStore(writer: legacyDb.writer).save(card: labCard(pageIndex: 0, encounter: legacyEncounter), patientId: legacyPatient, documentId: legacyDocument)
        let legacyExporter = ExportService(writer: legacyDb.writer)
        let data = try await legacyExporter.encode(try await legacyExporter.exportJSON())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["healthExams", "clinicalConclusions", "surgeries", "treatmentRecords", "reminders"] { json[key] = nil }
        if var appointments = json["appointments"] as? [[String: Any]] {
            for index in appointments.indices { appointments[index]["encounterId"] = nil; appointments[index]["purpose"] = nil }
            json["appointments"] = appointments
        }
        if var metrics = json["metrics"] as? [[String: Any]] {
            for index in metrics.indices { metrics[index]["healthExamId"] = nil }
            json["metrics"] = metrics
        }
        if var labReports = json["labReports"] as? [[String: Any]] {
            for index in labReports.indices { labReports[index]["reportSource"] = nil; labReports[index]["healthExamId"] = nil }
            json["labReports"] = labReports
        }
        let legacy = try await legacyExporter.decode(try JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.healthExams); XCTAssertNil(legacy.reminders)
        XCTAssertNil(legacy.appointments.first?.encounterId)
        let legacyTarget = try GRDBStore.inMemory()
        try await ExportService(writer: legacyTarget.writer).importJSON(legacy)
        let legacyCounts = try await tableCounts(legacyTarget, ["encounter", "appointment", "lab_report", "metric_sample", "health_exam", "clinical_conclusion", "surgery", "treatment_record", "reminder"])
        XCTAssertEqual(legacyCounts,
                       [1, 1, 1, 1, 0, 0, 0, 0, 0])
        let legacyApptRow = try await legacyTarget.writer.read { try Row.fetchOne($0, sql: "SELECT encounter_id, purpose FROM appointment") }
        let legacyAppointment = try XCTUnwrap(legacyApptRow)
        XCTAssertNil(legacyAppointment["encounter_id"] as String?)
        XCTAssertNil(legacyAppointment["purpose"] as String?)
        let legacyReportRow = try await legacyTarget.writer.read { try Row.fetchOne($0, sql: "SELECT report_source, health_exam_id FROM lab_report") }
        let legacyReport = try XCTUnwrap(legacyReportRow)
        XCTAssertNil(legacyReport["report_source"] as String?)
        XCTAssertNil(legacyReport["health_exam_id"] as String?)
    }
}
