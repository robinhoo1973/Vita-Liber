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
        let target = try GRDBStore.inMemory()
        try await ExportService(writer: target.writer).importJSON(envelope)
        let row = try await target.writer.read { try Row.fetchOne($0, sql: "SELECT * FROM prescription") }
        let restored = try XCTUnwrap(row)
        XCTAssertEqual(restored["advice_text"] as String, "Reviewed advice\nDrug A\nDrug B")
        let calendar = Calendar(identifier: .gregorian)
        let expected = try XCTUnwrap(EntityCardProjection.parseDate("2020-01-02", calendar: calendar))
        XCTAssertEqual(restored["prescribed_at"] as Double, expected.timeIntervalSince1970)
        let count = try await target.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(DISTINCT entity_id) FROM ocr_card_commit") }
        XCTAssertEqual(count, 1)
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
        let advice = try await db.writer.read { try String.fetchOne($0, sql: "SELECT advice_text FROM prescription") }
        XCTAssertEqual(advice, "A\nB\nC")
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
}
