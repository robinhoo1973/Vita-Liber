import XCTest
import Foundation
import UIKit
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

// binds: SU-M2-PENDINGCARD / SU-M1c-EXPORT (FR6.1 / FR6.9 / BR-001 / BR-003)
@MainActor
final class OcrCardQueueAcceptanceTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDownWithError() throws {
        for directory in directories {
            try FileManager.default.removeItem(at: directory)
        }
        directories = []
        try super.tearDownWithError()
    }

    private struct Fixture {
        let database: GRDBStore
        let patient: UUID
        let documents: DocumentStore
        let pending: PendingCardStore
        let scheduler: any ReminderScheduling
        let docs: DocumentsState
        let directory: URL
    }

    private actor PageRecognizer: ImageTextRecognizing {
        enum Failure: Error { case notAnImage, pageFailed }
        let pages: [[String]?]
        let confidence: Double
        var cursor = 0

        init(pages: [[String]?], confidence: Double) {
            self.pages = pages
            self.confidence = confidence
        }

        func recognize(_ data: Data) async throws -> ImageInputRules.Recognition {
            // Reject raw PDF bytes: duplicate resolution must render pages too.
            guard data.starts(with: [0x89, 0x50, 0x4e, 0x47]) else { throw Failure.notAnImage }
            let page = pages[cursor % pages.count]
            cursor += 1
            guard let page else { throw Failure.pageFailed }
            return .init(lines: page, confidence: confidence)
        }
    }

    private actor FailingScheduler: ReminderScheduling {
        enum Failure: Error { case unavailable }
        func schedule(dose notifyId: String, at fireAt: Date, route: AppRoute?) async throws { throw Failure.unavailable }
        func cancel(_ notifyIds: [String]) async throws { throw Failure.unavailable }
        func pending() async throws -> [String: Date] { [:] }
        func delivered() async throws -> Set<String> { [] }
    }

    private let lab = ["检验报告", "日期：2026-09-01", "血红蛋白 150 g/L 130-175", "白细胞 6.5 10^9/L", "红细胞 4.5"]

    private var image: Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    private func fixture(pages: [[String]?], confidence: Double = 0.9,
                         scheduler: any ReminderScheduling = InMemoryReminderScheduler()) async throws -> Fixture {
        let database = try GRDBStore.inMemory()
        let patient = UUID()
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'Owner', 'self', 0, 0)", arguments: [patient.uuidString])
            try db.execute(sql: "INSERT INTO local_owner (id, display_name, self_patient_id, created_at) VALUES (?, 'Owner', ?, 0)", arguments: [UUID().uuidString, patient.uuidString])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-journey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let documents = DocumentStore(writer: database.writer)
        let pending = PendingCardStore(writer: database.writer)
        let docs = DocumentsState(store: documents,
                                  pipeline: OCRPipeline(recognizer: PageRecognizer(pages: pages, confidence: confidence),
                                                        grayscaleDecoder: GrayscaleImageDecoder()),
                                  decoder: PDFKitDecoder(), originalsDir: directory,
                                  understandingEngine: NLTextUnderstanding(), pendingCards: pending,
                                  scheduler: scheduler, cardStore: OCRCardStore(writer: database.writer))
        return Fixture(database: database, patient: patient, documents: documents,
                       pending: pending, scheduler: scheduler, docs: docs, directory: directory)
    }

    private func imageDraft(_ fixture: Fixture) async throws -> DocumentsState.ImportDraft {
        let data = image
        let prepared = await fixture.docs.prepareImageDraft(patientId: fixture.patient, originalData: data,
                                                          processedData: data, mimeType: "image/png",
                                                          docType: nil, title: nil, isSensitive: true, origin: "camera")
        return try XCTUnwrap(prepared)
    }

    private func pdfURL(_ fixture: Fixture, count: Int) throws -> URL {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for index in 0..<count {
                context.beginPage()
                ("Page \(index + 1)" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
            }
        }
        let url = fixture.directory.appendingPathComponent("report.pdf")
        try data.write(to: url)
        return url
    }

    private func reviewed(_ input: MatchedCard) -> MatchedCard {
        var card = input
        for index in card.shared.indices { _ = card.shared[index].confirm() }
        for row in card.rows.indices {
            for index in card.rows[row].fields.indices where card.rows[row].fields[index].key != "metric_key" {
                _ = card.rows[row].fields[index].confirm()
            }
        }
        return card
    }

    func test_documentPagesArePersistedWithFailedPlaceholder() async throws {
        let f = try await fixture(pages: [[]])
        let documentID = try await f.documents.save(patientId: f.patient, docType: "Report", sha256: "pdf:pages",
            mimeType: "application/pdf", origin: "import", isSensitive: true, metaJSON: nil, title: nil,
            grade: "D", pages: [.init(index: 0, text: "First"), .init(index: 1, text: nil, status: "failed"),
                                .init(index: 2, text: "Third")])
        let pages = try await f.documents.pages(documentId: documentID)
        XCTAssertEqual(pages.map(\.index), [0, 1, 2])
        XCTAssertEqual(pages.map(\.status), ["ok", "failed", "ok"])
        XCTAssertNil(pages[1].text)
        var field = CandidateField(key: "lab_item", displayLabel: "Lab", rawText: "Glucose 5.6", confidence: 0.9)
        _ = field.confirm()
        try await f.documents.saveOCRResult(documentId: documentID, patientId: f.patient, pageIndex: 2,
                                             fields: [field], engineVersion: "test")
        let pageIndex = try await f.database.writer.read { try Int.fetchOne($0, sql: "SELECT page_index FROM ocr_result LIMIT 1") }
        XCTAssertEqual(pageIndex, 2)
    }

    func test_pendingCardCarriesPageAndRows() async throws {
        let f = try await fixture(pages: [[]])
        let documentID = try await f.documents.save(patientId: f.patient, docType: "Report", sha256: "review-source-fixture",
            mimeType: "image/png", origin: "import", isSensitive: true, metaJSON: nil, title: nil,
            grade: "D", pages: [.init(index: 0, text: "First"), .init(index: 1, text: "Second")])
        let payload = PendingCardPayload(shared: ["measured_at": "2026-09-01"],
                                         rows: [["raw_label": "A", "value": "1"], ["raw_label": "B", "value": "2"]])
        var draft = PendingCardDraft(patientId: f.patient, sourceType: "ocr", sourceDocId: documentID, sourcePage: 0,
            cardKind: "metric_sample", incompleteFields: [.init(key: "unit")], partialData: payload, rawText: "First")
        let first = try await f.pending.upsert(draft)
        let again = try await f.pending.upsert(draft)
        XCTAssertEqual(first, again)
        draft.sourcePage = 1
        let second = try await f.pending.upsert(draft)
        XCTAssertNotEqual(first, second)
        let pending = try await f.pending.card(id: first)
        XCTAssertEqual(pending?.sourcePage, 0)
        XCTAssertEqual(pending?.partialData.rows.count, 2)
        XCTAssertEqual(pending?.partialData.shared["measured_at"], "2026-09-01")
    }

    func test_hospitalSamplesAreWrittenWithPageReference() async throws {
        let f = try await fixture(pages: [lab + ["医院：市一医院"]])
        let draft = try await imageDraft(f)
        let saved = await f.docs.commitDraft(draft)
        XCTAssertTrue(saved)
        let card = try XCTUnwrap(f.docs.currentEntityCard)
        let result = await f.docs.confirmEntityCard(card, confirmed: reviewed(card))
        XCTAssertEqual(result?.writtenCount, 2)
        let documentID = try XCTUnwrap(f.docs.entityQueueDocumentId)
        let rows = try await f.database.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM metric_sample ORDER BY raw_label") }
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(row["origin"] as String, "hospital")
            XCTAssertEqual(row["self_measured"] as Int, 0)
            XCTAssertEqual(row["source_ref"] as String, "doc:\(documentID.uuidString)#p0")
        }
        let hgb = rows.first { ($0["raw_label"] as String?) == "血红蛋白" }
        XCTAssertEqual(hgb?["ref_low"] as Double?, 130)
        XCTAssertEqual(hgb?["ref_high"] as Double?, 175)
        XCTAssertEqual(hgb?["ref_source_label"] as String?, "市一医院")
        XCTAssertNil(hgb?["code_concept_id"] as String?)
    }

    func test_backupRoundTripsDocumentPages() async throws {
        let f = try await fixture(pages: [[]])
        _ = try await f.documents.save(patientId: f.patient, docType: "Report", sha256: "pdf:backup",
            mimeType: "application/pdf", origin: "import", isSensitive: false, metaJSON: nil, title: "Report.pdf",
            ocrText: "A\n---\nB", grade: "C", pages: [.init(index: 0, text: "A"), .init(index: 1, text: "B")])
        let envelope = try await ExportService(writer: f.database.writer).exportJSON()
        XCTAssertEqual(envelope.documents?.first?.pages?.count, 2)
        let destination = try GRDBStore.inMemory()
        _ = try await BackupService(writer: destination.writer).restore(envelope: envelope)
        let restored = try await destination.writer.read {
            try Row.fetchAll($0, sql: "SELECT page_index, ocr_text FROM document_page ORDER BY page_index")
        }
        XCTAssertEqual(restored.map { $0["page_index"] as Int }, [0, 1])
        XCTAssertEqual(restored.map { $0["ocr_text"] as String? }, ["A", "B"])
        var legacy = envelope
        legacy.documents = envelope.documents?.map { var document = $0; document.pages = nil; return document }
        let legacyDestination = try GRDBStore.inMemory()
        _ = try await BackupService(writer: legacyDestination.writer).restore(envelope: legacy)
        let count = try await legacyDestination.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM document_page") }
        XCTAssertEqual(count, 0)
    }

    func test_pdfReturnsDraftWithoutSavingAndPreservesFailedAndEmptyIndexes() async throws {
        let f = try await fixture(pages: [lab, nil, [], lab])
        let url = try pdfURL(f, count: 4)
        let prepared = await f.docs.importDocument(patientId: f.patient, url: url, docType: nil)
        let draft = try XCTUnwrap(prepared)
        XCTAssertEqual(draft.pages.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(draft.pages.map(\.status), ["ok", "failed", "ok", "ok"])
        XCTAssertTrue(draft.pages[2].text.isEmpty)
        XCTAssertEqual(draft.entityCards.map(\.pageIndex), [0, 3])
        XCTAssertTrue(draft.isSensitive)
        let before = try await f.documents.list(patientId: f.patient)
        XCTAssertTrue(before.isEmpty)
        let saved = await f.docs.commitDraft(draft)
        XCTAssertTrue(saved)
        let documentID = try XCTUnwrap(f.docs.entityQueueDocumentId)
        let storedPages = try await f.documents.pages(documentId: documentID)
        XCTAssertEqual(storedPages.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(storedPages.map(\.status), ["ok", "failed", "ok", "ok"])
    }

    func test_pdfNeverBorrowsRequiredFieldsFromAnotherPage() async throws {
        let f = try await fixture(pages: [["检验报告", "日期：2026-09-01"], ["血红蛋白 150 g/L"]])
        let url = try pdfURL(f, count: 2)
        let prepared = await f.docs.importPDF(patientId: f.patient, url: url, docType: nil)
        let draft = try XCTUnwrap(prepared)
        XCTAssertEqual(draft.pages.count, 2)
        XCTAssertTrue(draft.entityCards.isEmpty)
    }

    func test_sourceRendererOpensRequestedPDFPageAndRejectsMissingPage() async throws {
        let f = try await fixture(pages: [lab, []])
        let url = try pdfURL(f, count: 2)
        let data = try Data(contentsOf: url)
        let first = try DocumentSourceRenderer.image(data: data, mimeType: "application/pdf", pageIndex: 0)
        let second = try DocumentSourceRenderer.image(data: data, mimeType: "application/pdf", pageIndex: 1)
        XCTAssertNotNil(first.pngData())
        XCTAssertNotEqual(first.pngData(), second.pngData())
        XCTAssertThrowsError(try DocumentSourceRenderer.image(data: data, mimeType: "application/pdf", pageIndex: 2))
        let documentID = UUID()
        let reference = DocumentSourcePageReference(sourceRef: "doc:\(documentID.uuidString)#p1")
        XCTAssertEqual(reference?.documentId, documentID)
        XCTAssertEqual(reference?.pageIndex, 1)
        XCTAssertNil(DocumentSourcePageReference(sourceRef: "doc:\(documentID.uuidString)#p-1"))
    }

    func test_notificationFailureKeepsSavedPendingCardAndDoesNotReportDeferralSuccess() async throws {
        let f = try await fixture(pages: [lab], scheduler: FailingScheduler())
        let draft = try await imageDraft(f)
        let saved = await f.docs.commitDraft(draft)
        XCTAssertTrue(saved)
        let card = try XCTUnwrap(f.docs.currentEntityCard)
        let deferred = await f.docs.deferEntityCard(card)
        XCTAssertFalse(deferred)
        XCTAssertNotNil(f.docs.activeImport?.notificationError)
        XCTAssertEqual(f.docs.currentEntityCard?.id, card.id)
        let pending = try await f.pending.list(patientId: f.patient)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].partialData.card?.id, card.id)
    }

    func test_reenteringPendingCardUsesUnwrittenCurrentQueueEdits() async throws {
        let f = try await fixture(pages: [lab])
        let draft = try await imageDraft(f)
        let saved = await f.docs.commitDraft(draft)
        XCTAssertTrue(saved)
        var card = try XCTUnwrap(f.docs.currentEntityCard)
        let value = try XCTUnwrap(card.rows[0].fields.firstIndex { $0.key == "value" })
        card.reviseField(at: value, rowId: card.rows[0].id, to: "155")
        XCTAssertTrue(f.docs.updateEntityCard(card))
        let pendingRows = try await f.pending.list(patientId: f.patient)
        let pending = try XCTUnwrap(pendingRows.first)
        let resumed = await f.docs.resumePendingCard(pending)
        XCTAssertEqual(resumed?.rows[0].fields[value].value, "155")
        XCTAssertTrue(f.docs.pendingReviews.isEmpty, "An active import must not acquire a second editable snapshot")
    }

    func test_discardedRowWithoutFactsDoesNotLockSharedCorrections() async throws {
        let f = try await fixture(pages: [lab])
        let draft = try await imageDraft(f)
        let saved = await f.docs.commitDraft(draft)
        XCTAssertTrue(saved)
        let initial = try XCTUnwrap(f.docs.currentEntityCard)
        var edited = initial
        for index in edited.rows[0].fields.indices { edited.rows[0].fields[index].reject() }
        let result = await f.docs.confirmEntityCard(initial, confirmed: edited)
        XCTAssertEqual(result?.writtenCount, 0)
        XCTAssertEqual(result?.resolved, false)
        XCTAssertFalse(f.docs.activeImport?.committedCards.contains(initial.id) == true)
        let deferred = await f.docs.deferRemainingEntityCards()
        XCTAssertTrue(deferred)
        let rows = try await f.pending.list(patientId: f.patient)
        let pending = try XCTUnwrap(rows.first)
        _ = await f.docs.resumePendingCard(pending)
        XCTAssertEqual(f.docs.pendingReviews[pending.id]?.sharedCommitted, false)
    }

    func test_pdfDuplicateReplacementReturnsReviewedDraftAndDoesNotArchiveEarly() async throws {
        let f = try await fixture(pages: [lab, []])
        let url = try pdfURL(f, count: 2)
        let data = try Data(contentsOf: url)
        let existing = try await f.documents.save(patientId: f.patient, docType: L10n.docTypeReport,
            sha256: "pdf:" + DocumentsState.hash(data), mimeType: "application/pdf", origin: "import",
            isSensitive: true, metaJSON: nil, title: "Existing", grade: "D")
        let duplicate = await f.docs.importPDF(patientId: f.patient, url: url, docType: nil, isSensitive: false)
        XCTAssertNil(duplicate)
        XCTAssertNotNil(f.docs.pendingDuplicate)
        let resolved = await f.docs.resolveDuplicate(.replace)
        let draft = try XCTUnwrap(resolved)
        XCTAssertEqual(draft.pages.map(\.index), [0, 1])
        XCTAssertEqual(draft.replaceDocumentId, existing)
        XCTAssertTrue(draft.isSensitive)
        let old = try await f.documents.fetch(id: existing)
        XCTAssertEqual(old?.status, "active")
        let documents = try await f.documents.list(patientId: f.patient)
        XCTAssertEqual(documents.count, 1)
    }

    func test_documentCorrectionsAndRejectionsFeedMatchingWithoutPromotingFields() async throws {
        let f = try await fixture(pages: [lab])
        var draft = try await imageDraft(f)
        let edited = try XCTUnwrap(draft.pages[0].fields.firstIndex { $0.key == "lab_item" && $0.value.contains("血红蛋白") })
        draft.pages[0].fields[edited].revise(to: "血红蛋白 151")
        let rejected = try XCTUnwrap(draft.pages[0].fields.firstIndex { $0.key == "lab_item" && $0.value.contains("白细胞") })
        draft.pages[0].fields[rejected].reject()
        let saved = await f.docs.commitDraft(draft)
        XCTAssertTrue(saved)
        let card = try XCTUnwrap(f.docs.currentEntityCard)
        XCTAssertEqual(card.rows.count, 2)
        XCTAssertEqual(card.rows[0].fields.first { $0.key == "value" }?.value, "151")
        XCTAssertEqual(card.rows[0].fields.first { $0.key == "value" }?.originalValue, "150")
        XCTAssertFalse(card.allFields.contains { $0.isConfirmed })
        let documents = try await f.documents.list(patientId: f.patient)
        XCTAssertEqual(documents.first?.grade, "D")
        let count = try await f.database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(count, 0)
    }

    func test_manualTypeDoesNotExcludeOtherQualifyingCardsOrAutoCreatePrescription() async throws {
        let lines = ["检验报告", "项目", "参考范围", "门诊病历", "日期：2026-09-01", "科室：内科",
                     "药品名称：阿莫西林胶囊", "医院：市医院", "血红蛋白 150 g/L"]
        let f = try await fixture(pages: [lines])
        var draft = try await imageDraft(f)
        draft.docType = L10n.docTypePrescription
        draft.docTypeManuallyChosen = true
        let saved = await f.docs.commitDraft(draft)
        XCTAssertTrue(saved)
        XCTAssertEqual(Set(f.docs.entityQueue.map(\.kind)), ["metric_sample", "encounter", "prescription"])
        XCTAssertEqual(f.docs.entityQueue.filter { $0.kind == "prescription" }.count, 1)
        let count = try await f.database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM prescription") }
        XCTAssertEqual(count, 0)
    }

    func test_lowRecognitionConfidenceSurvivesDeferralAndResume() async throws {
        let f = try await fixture(pages: [lab], confidence: 0.2)
        let draft = try await imageDraft(f)
        XCTAssertTrue(draft.pages[0].fields.allSatisfy { $0.confidence <= 0.2 })
        let saved = await f.docs.commitDraft(draft)
        XCTAssertTrue(saved)
        let card = try XCTUnwrap(f.docs.currentEntityCard)
        let deferred = await f.docs.deferEntityCard(card)
        XCTAssertTrue(deferred)
        let cards = try await f.pending.list(patientId: f.patient)
        let pending = try XCTUnwrap(cards.first)
        let restored = await f.docs.resumePendingCard(pending)
        XCTAssertEqual(restored, card)
        XCTAssertTrue(restored?.allFields.filter { $0.key != "metric_key" }.allSatisfy { $0.confidence <= 0.2 } == true)
    }

    func test_allLaterAndResumedLaterPreserveCurrentEditsAndStableRowIdentity() async throws {
        let f = try await fixture(pages: [lab])
        let draft = try await imageDraft(f)
        let saved = await f.docs.commitDraft(draft)
        XCTAssertTrue(saved)
        var card = try XCTUnwrap(f.docs.currentEntityCard)
        let rowID = card.rows[0].id
        let valueIndex = try XCTUnwrap(card.rows[0].fields.firstIndex { $0.key == "value" })
        card.reviseField(at: valueIndex, rowId: rowID, to: "152")
        XCTAssertTrue(f.docs.updateEntityCard(card))
        let deferred = await f.docs.deferRemainingEntityCards()
        XCTAssertTrue(deferred)
        let pendingCards = try await f.pending.list(patientId: f.patient)
        let pending = try XCTUnwrap(pendingCards.first)
        let resumed = await f.docs.resumePendingCard(pending)
        var edited = try XCTUnwrap(resumed)
        XCTAssertEqual(edited.rows[0].id, rowID)
        XCTAssertEqual(edited.rows[0].fields[valueIndex].value, "152")
        edited.reviseField(at: valueIndex, rowId: rowID, to: "153")
        let deferredAgain = await f.docs.deferPendingCard(pending, edited: edited)
        XCTAssertTrue(deferredAgain)
        let fetched = try await f.pending.card(id: pending.id)
        let stored = try XCTUnwrap(fetched)
        let final = try stored.matchedCard()
        XCTAssertEqual(final.rows[0].fields[valueIndex].value, "153")
        XCTAssertEqual(final.rows[0].fields[valueIndex].originalValue, "150")
        XCTAssertFalse(final.rows[0].fields[valueIndex].isConfirmed)
    }

    func test_partialSaveKeepsResidualAndRetryDoesNotDuplicateFacts() async throws {
        let f = try await fixture(pages: [lab])
        let draft = try await imageDraft(f)
        let saved = await f.docs.commitDraft(draft)
        XCTAssertTrue(saved)
        let initial = try XCTUnwrap(f.docs.currentEntityCard)
        let result = await f.docs.confirmEntityCard(initial, confirmed: reviewed(initial))
        XCTAssertEqual(result?.writtenCount, 2)
        XCTAssertEqual(result?.resolved, false)
        var residual = try XCTUnwrap(f.docs.currentEntityCard)
        XCTAssertEqual(residual.rows.count, 1)
        XCTAssertEqual(residual.rows[0].id, initial.rows[2].id)
        var unit = FieldDraft(key: "unit", value: "10^12/L")
        _ = unit.confirm()
        residual.rows[0].fields.append(unit)
        let completed = await f.docs.confirmEntityCard(residual, confirmed: reviewed(residual))
        XCTAssertEqual(completed?.writtenCount, 1)
        XCTAssertEqual(completed?.resolved, true)
        let count = try await f.database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(count, 3)
        XCTAssertTrue(f.docs.entityQueue.isEmpty)
        XCTAssertNotNil(f.docs.activeImport, "The slot stays occupied until the host's actual onDismiss")
        let sessionID = try XCTUnwrap(f.docs.activeImport?.id)
        XCTAssertTrue(f.docs.finishImportPresentation(sessionID: sessionID))
        XCTAssertNil(f.docs.activeImport)
    }

    func test_queueCannotBeReplacedAndResumeCannotChangeItsOwner() async throws {
        let f = try await fixture(pages: [lab])
        let draft = try await imageDraft(f)
        let saved = await f.docs.commitDraft(draft)
        XCTAssertTrue(saved)
        let documentID = try XCTUnwrap(f.docs.entityQueueDocumentId)
        let initialID = f.docs.currentEntityCard?.id
        let other = UUID()
        try await f.database.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'Other', 'other', 0, 0)", arguments: [other.uuidString])
        }
        let otherDocument = try await f.documents.save(patientId: other, docType: "Report", sha256: "other-source-fixture",
            mimeType: "image/png", origin: "import", isSensitive: true, metaJSON: nil, title: nil,
            grade: "D", pages: [.init(index: 0, text: "Other")])
        let original = try XCTUnwrap(f.docs.currentEntityCard)
        let card = MatchedCard(kind: original.kind, pageIndex: original.pageIndex, shared: original.shared,
            rows: original.rows, allFieldCoverage: original.allFieldCoverage, requiredCoverage: original.requiredCoverage,
            missingRequired: original.missingRequired, level: original.level)
        let pendingID = try await f.pending.upsert(.init(patientId: other, sourceType: "ocr", sourceDocId: otherDocument,
            sourcePage: 0, cardKind: card.kind, incompleteFields: [], partialData: PendingCardPayload(card: card), rawText: "Other"))
        let fetched = try await f.pending.card(id: pendingID)
        let pending = try XCTUnwrap(fetched)
        _ = await f.docs.resumePendingCard(pending)
        XCTAssertEqual(f.docs.entityQueuePatientId, f.patient)
        XCTAssertEqual(f.docs.entityQueueDocumentId, documentID)
        let replacement = await f.docs.prepareImageDraft(patientId: other, originalData: image, processedData: image,
            mimeType: "image/png", docType: nil, title: nil, isSensitive: true)
        XCTAssertNil(replacement)
        XCTAssertEqual(f.docs.currentEntityCard?.id, initialID)
    }

    func test_failedOriginalWriteKeepsDraftAndCreatesNoDocument() async throws {
        let f = try await fixture(pages: [lab])
        let draft = try await imageDraft(f)
        try Data([1]).write(to: f.directory.appendingPathComponent("originals"))
        let saved = await f.docs.commitDraft(draft)
        XCTAssertFalse(saved)
        XCTAssertEqual(f.docs.activeImport?.draft?.id, draft.id)
        XCTAssertNotNil(f.docs.lastImportError)
        let documents = try await f.documents.list(patientId: f.patient)
        XCTAssertTrue(documents.isEmpty)
    }

    func test_documentLaterRetainsOriginalAndEditedSourceBackedCard() async throws {
        let f = try await fixture(pages: [lab])
        var draft = try await imageDraft(f)
        let index = try XCTUnwrap(draft.pages[0].fields.firstIndex { $0.key == "lab_item" })
        draft.pages[0].fields[index].revise(to: "血红蛋白 154")
        let deferred = await f.docs.deferImportDraft(draft)
        XCTAssertTrue(deferred)
        let pending = try await f.pending.list(patientId: f.patient)
        let card = try XCTUnwrap(pending.first)
        XCTAssertNotNil(card.sourceDocId)
        XCTAssertEqual(card.sourcePage, 0)
        let restored = try card.matchedCard()
        XCTAssertEqual(restored.rows[0].fields.first { $0.key == "value" }?.value, "154")
        let stored = try await f.documents.fetch(id: try XCTUnwrap(card.sourceDocId))
        XCTAssertTrue(stored?.metaJSON?.contains("original_path") == true)
        XCTAssertEqual(stored?.grade, "D")
    }
}
