import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols

// binds: SU-M2-PENDINGCARD / SU-M1c-EXPORT (FR6.1 页语义 / FR6.9 页级多卡 / FR13.5)
/// Infrastructure 半场（真实 GRDB，macOS CI）：页文本落库、页级留痕、待办卡页号与多行载荷、
/// 医院来源检验值写入、备份往返。
@MainActor
final class OcrCardQueueAcceptanceTests: XCTestCase {
    private func makeStore() async throws -> (GRDBStore, UUID) {
        let db = try GRDBStore.inMemory()
        let patient = UUID()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'Owner', 'self', 0, 0)", arguments: [patient.uuidString])
            try db.execute(sql: "INSERT INTO local_owner (id, display_name, self_patient_id, created_at) VALUES (?, 'Owner', ?, 0)", arguments: [UUID().uuidString, patient.uuidString])
        }
        return (db, patient)
    }

    /// FR6.1 页语义：单条 OCR 记录（PDF）三页——第 2 页识别失败也占位保页号；
    /// 拼接文本保留页序（失败页为空段），不再过滤失败页。
    func test_documentPagesArePersistedWithFailedPlaceholder() async throws {
        let (db, patient) = try await makeStore()
        let store = DocumentStore(writer: db.writer)
        let pages = [DocumentStore.Page(index: 0, text: "第一页", status: "ok"),
                     DocumentStore.Page(index: 1, text: nil, status: "failed"),
                     DocumentStore.Page(index: 2, text: "第三页", status: "ok")]
        let docId = try await store.save(patientId: patient, docType: "检验报告", sha256: "pdf:x",
                                         mimeType: "application/pdf", origin: "import", isSensitive: true,
                                         metaJSON: nil, title: "报告.pdf", ocrText: "第一页\n---\n\n---\n第三页",
                                         grade: "C", pages: pages)
        let stored = try await store.pages(documentId: docId)
        XCTAssertEqual(stored.map(\.index), [0, 1, 2])
        XCTAssertEqual(stored.map(\.status), ["ok", "failed", "ok"])
        XCTAssertNil(stored[1].text)
        XCTAssertEqual(stored[2].text, "第三页")
        // 页级留痕写真实页号
        try await store.saveOCRResult(documentId: docId, pageIndex: 2,
                                      fields: [CandidateField(key: "lab_item", displayLabel: "项目", rawText: "血糖 5.6", confidence: 0.9)],
                                      engineVersion: "test")
        let pageIndex = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT page_index FROM ocr_result LIMIT 1") }
        XCTAssertEqual(pageIndex, 2)
    }

    /// FR6.9：待办卡精确到页；同 (文档, 页, 卡类) 复用一张；载荷为共享 + 多行。
    func test_pendingCardCarriesPageAndRows() async throws {
        let (db, patient) = try await makeStore()
        let docStore = DocumentStore(writer: db.writer)
        let docId = try await docStore.save(patientId: patient, docType: "检验报告", sha256: "img:x",
                                            mimeType: "image/png", origin: "camera", isSensitive: true,
                                            metaJSON: nil, title: nil, ocrText: "血糖 5.6", grade: "C",
                                            pages: [DocumentStore.Page(index: 0, text: "血糖 5.6", status: "ok")])
        let pending = PendingCardStore(writer: db.writer)
        let payload = PendingCardPayload(shared: ["measured_at": "2026-09-01"],
                                         rows: [["raw_label": "血糖", "value": "5.6"], ["raw_label": "尿酸", "value": "300"]])
        let draft = PendingCardDraft(patientId: patient, sourceType: "ocr", sourceDocId: docId, sourcePage: 0,
                                     cardKind: "metric_sample",
                                     incompleteFields: [IncompleteField(key: "unit", reason: "缺单位")],
                                     partialData: payload, rawText: "血糖 5.6\n尿酸 300")
        let first = try await pending.upsert(draft)
        let again = try await pending.upsert(draft)
        XCTAssertEqual(first, again, "同文档同页同卡类复用一张")
        var otherPage = draft
        otherPage.sourcePage = 1
        let second = try await pending.upsert(otherPage)
        XCTAssertNotEqual(first, second, "另一页同卡类是另一张卡")
        let card = try await pending.card(id: first)
        XCTAssertEqual(card?.sourcePage, 0)
        XCTAssertEqual(card?.partialData.rows.count, 2)
        XCTAssertEqual(card?.partialData.shared["measured_at"], "2026-09-01")
        // 旧行（纯字典 JSON）仍可读
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE pending_card SET partial_data = ? WHERE id = ?",
                           arguments: [#"{"drug_name":"阿莫西林"}"#, first])
        }
        let legacy = try await pending.card(id: first)
        XCTAssertEqual(legacy?.partialData.shared, ["drug_name": "阿莫西林"])
        XCTAssertTrue(legacy?.partialData.rows.isEmpty == true)
    }

    /// FR7.9/FR7.2：确认后的检验项目落 metric_sample 医院来源行（A 级参考范围随行，
    /// source_ref 回到文档页，编码只在有确认建议时回填）。
    func test_hospitalSamplesAreWrittenWithPageReference() async throws {
        let (db, patient) = try await makeStore()
        let docId = UUID()
        try await db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO document_file (id, patient_id, doc_type, sha256, mime_type, origin, is_sensitive, grade, created_at, updated_at)
                VALUES (?, ?, '检验报告', 'x', 'image/png', 'camera', 1, 'C', 0, 0)
                """, arguments: [docId.uuidString, patient.uuidString])
        }
        let trends = TrendQueryStore(writer: db.writer)
        let measured = Date(timeIntervalSince1970: 1_700_006_400)
        let written = try await trends.addHospitalSamples(patientId: patient, documentId: docId, pageIndex: 1, samples: [
            HospitalSample(metricKey: "lab.血红蛋白", rawLabel: "血红蛋白", value: 150, unit: "g/L", measuredAt: measured,
                           refLow: 130, refHigh: 175, refSourceLabel: "市一医院", codeConceptId: nil),
            HospitalSample(metricKey: "bloodGlucose", rawLabel: "血糖", value: 5.6, unit: "mmol/L", measuredAt: measured,
                           refLow: nil, refHigh: nil, refSourceLabel: nil, codeConceptId: nil),
        ])
        XCTAssertEqual(written, 2)
        let rows = try await db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM metric_sample ORDER BY metric_key")
        }
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(row["origin"] as String, "hospital")
            XCTAssertEqual(row["self_measured"] as Int, 0)
            XCTAssertEqual(row["source_ref"] as String, "doc:\(docId.uuidString)#p1")
            XCTAssertEqual(row["measured_at"] as Double, measured.timeIntervalSince1970)
        }
        let hgb = rows.first { ($0["raw_label"] as String?) == "血红蛋白" }
        XCTAssertEqual(hgb?["ref_low"] as Double?, 130)
        XCTAssertEqual(hgb?["ref_high"] as Double?, 175)
        XCTAssertEqual(hgb?["ref_source_label"] as String?, "市一医院")
        XCTAssertEqual(hgb?["code_concept_id"] as DatabaseValue?, .null)
    }

    /// FR13.5：页文本随 .vlbu documents.pages 往返；恢复后按 (文档, 页) 唯一。
    func test_backupRoundTripsDocumentPages() async throws {
        let (source, patient) = try await makeStore()
        let store = DocumentStore(writer: source.writer)
        _ = try await store.save(patientId: patient, docType: "检验报告", sha256: "pdf:x",
                                 mimeType: "application/pdf", origin: "import", isSensitive: false,
                                 metaJSON: nil, title: "报告.pdf", ocrText: "A\n---\nB", grade: "C",
                                 pages: [DocumentStore.Page(index: 0, text: "A", status: "ok"),
                                         DocumentStore.Page(index: 1, text: "B", status: "ok")])
        let exporter = ExportService(writer: source.writer)
        let envelope = try await exporter.exportJSON()
        XCTAssertEqual(envelope.documents?.first?.pages?.count, 2)
        let destination = try GRDBStore.inMemory()
        _ = try await BackupService(writer: destination.writer).restore(envelope: envelope)
        let restored = try await destination.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT page_index, ocr_text, status FROM document_page ORDER BY page_index")
        }
        XCTAssertEqual(restored.map { $0["page_index"] as Int }, [0, 1])
        XCTAssertEqual(restored.map { $0["ocr_text"] as String? }, ["A", "B"])
        // 旧包（无 pages）恢复不报错、不造页
        var legacy = envelope
        legacy.documents = envelope.documents?.map { var d = $0; d.pages = nil; return d }
        let legacyDestination = try GRDBStore.inMemory()
        _ = try await BackupService(writer: legacyDestination.writer).restore(envelope: legacy)
        let count = try await legacyDestination.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM document_page") }
        XCTAssertEqual(count, 0)
    }
}

// MARK: - App 层队列（DocumentsState 扩展；VitaLiber 目标）

import SwiftUI
@testable import VitaLiber

@MainActor
final class EntityCardQueueAcceptanceTests: XCTestCase {
    private var originalsDirs: [URL] = []
    override func tearDownWithError() throws {
        for dir in originalsDirs { try? FileManager.default.removeItem(at: dir) }   // try?-ok: 清理尽力而为
        originalsDirs = []
        try super.tearDownWithError()
    }

    private struct Fixture {
        let store: GRDBStore
        let patient: UUID
        let docs: DocumentsState
        let scheduler: InMemoryReminderScheduler
        let pendingCards: PendingCardStore
        let trends: TrendQueryStore
    }

    private func makeFixture(lines: [String]) async throws -> Fixture {
        let store = try GRDBStore.inMemory()
        let patient = UUID()
        try await store.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'Owner', 'self', 0, 0)", arguments: [patient.uuidString])
            try db.execute(sql: "INSERT INTO local_owner (id, display_name, self_patient_id, created_at) VALUES (?, 'Owner', ?, 0)", arguments: [UUID().uuidString, patient.uuidString])
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vl-cards-\(UUID().uuidString)", isDirectory: true)
        originalsDirs.append(dir)
        let scheduler = InMemoryReminderScheduler()
        let pendingCards = PendingCardStore(writer: store.writer)
        let trends = TrendQueryStore(writer: store.writer)
        let docs = DocumentsState(
            store: DocumentStore(writer: store.writer),
            pipeline: OCRPipeline(recognizer: StubImageTextRecognizer(scripted: .init(lines: lines, confidence: 0.9)),
                                  grayscaleDecoder: GrayscaleImageDecoder()),
            originalsDir: dir,
            prescriptionStore: PrescriptionStore(writer: store.writer),
            understandingEngine: NLTextUnderstanding(),
            pendingCards: pendingCards,
            encounterStore: EncounterStore(writer: store.writer),
            trendStore: trends,
            scheduler: scheduler)
        return Fixture(store: store, patient: patient, docs: docs, scheduler: scheduler, pendingCards: pendingCards, trends: trends)
    }

    private let labPage = ["检验报告", "日期：2026-09-01", "血红蛋白 150 g/L 130-175", "白细胞 6.5 10^9/L", "红细胞 4.5"]

    /// 单页检验报告：文档卡确认后 → document_page 1 行 + 页级留痕 + 实体队列含 1 张检验卡
    func test_documentCardCommitStartsEntityQueueWithPage() async throws {
        let f = try await makeFixture(lines: labPage)
        let draft = await f.docs.prepareImageDraft(patientId: f.patient, originalData: Data([1]), processedData: Data([1, 2]),
                                                   mimeType: "image/png", docType: nil, title: nil, isSensitive: true, origin: "camera")
        let unwrapped = try XCTUnwrap(draft)
        XCTAssertEqual(unwrapped.pages.count, 1)
        XCTAssertEqual(unwrapped.entityCards.map(\.kind), ["metric_sample"])
        XCTAssertEqual(unwrapped.entityCards.first?.rows.count, 3)
        var confirmed = unwrapped
        confirmed.confirmationSet.confirmAllRemaining()
        await f.docs.commitDraft(confirmed)
        XCTAssertNil(f.docs.lastImportError)
        let pages = try await f.store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM document_page") }
        XCTAssertEqual(pages, 1)
        XCTAssertEqual(f.docs.entityQueue.count, 1)
        XCTAssertNotNil(f.docs.entityQueueDocumentId)
        XCTAssertEqual(f.docs.entityQueuePosition.0, 1)
        XCTAssertEqual(f.docs.entityQueuePosition.1, 1)
    }

    /// 确认检验卡 → metric_sample 医院行（缺单位行跳过）+ 页级留痕 + 出队
    func test_confirmEntityCardWritesHospitalSamplesAndDequeues() async throws {
        let f = try await makeFixture(lines: labPage)
        var draft = try XCTUnwrap(await f.docs.prepareImageDraft(patientId: f.patient, originalData: Data([1]), processedData: Data([1, 2]),
                                                                  mimeType: "image/png", docType: nil, title: nil, isSensitive: true, origin: "camera"))
        draft.confirmationSet.confirmAllRemaining()
        await f.docs.commitDraft(draft)
        let card = try XCTUnwrap(f.docs.currentEntityCard)
        let saved = await f.docs.confirmEntityCard(card, confirmed: card)
        XCTAssertTrue(saved)
        let rows = try await f.store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT raw_label, origin, self_measured, ref_low, ref_high, source_ref FROM metric_sample ORDER BY raw_label")
        }
        XCTAssertEqual(rows.count, 2, "血红蛋白 + 白细胞落库；红细胞缺单位跳过")
        XCTAssertEqual(rows.map { $0["origin"] as String }, ["hospital", "hospital"])
        XCTAssertEqual(rows.map { $0["self_measured"] as Int }, [0, 0])
        XCTAssertTrue((rows[0]["source_ref"] as String).hasSuffix("#p0"))
        let hgb = rows.first { ($0["raw_label"] as String) == "血红蛋白" }
        XCTAssertEqual(hgb?["ref_low"] as Double?, 130)
        let traces = try await f.store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ocr_result WHERE page_index = 0") }
        XCTAssertGreaterThan(traces ?? 0, 0)
        XCTAssertTrue(f.docs.entityQueue.isEmpty)
    }

    /// 稍后处理 → pending_card(source_page) + 1h 通知（route .pendingCard）；续确认 → 落库 + resolved + 通知取消
    func test_deferThenResumeCompletesPendingCard() async throws {
        let f = try await makeFixture(lines: labPage)
        var draft = try XCTUnwrap(await f.docs.prepareImageDraft(patientId: f.patient, originalData: Data([1]), processedData: Data([1, 2]),
                                                                  mimeType: "image/png", docType: nil, title: nil, isSensitive: true, origin: "camera"))
        draft.confirmationSet.confirmAllRemaining()
        await f.docs.commitDraft(draft)
        let card = try XCTUnwrap(f.docs.currentEntityCard)
        let deferred = await f.docs.deferEntityCard(card)
        XCTAssertTrue(deferred)
        XCTAssertTrue(f.docs.entityQueue.isEmpty)
        let pending = try await f.pendingCards.list(patientId: f.patient)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].sourcePage, 0)
        XCTAssertEqual(pending[0].cardKind, "metric_sample")
        XCTAssertEqual(pending[0].partialData.rows.count, 3)
        let notifyId = "pending-\(pending[0].id)"
        let fireAt = try await f.scheduler.pending()[notifyId]
        XCTAssertNotNil(fireAt)
        XCTAssertGreaterThan(fireAt!.timeIntervalSinceNow, 3500)
        XCTAssertLessThan(fireAt!.timeIntervalSinceNow, 3700)
        // 续确认：从页文本 + 载荷还原卡
        let resumed = try XCTUnwrap(await f.docs.resumePendingCard(pending[0]))
        XCTAssertEqual(resumed.kind, "metric_sample")
        XCTAssertEqual(resumed.pageIndex, 0)
        XCTAssertEqual(resumed.rows.count, 3)
        let completed = await f.docs.completePendingCard(pending[0], confirmed: resumed)
        XCTAssertTrue(completed)
        let metricCount = try await f.store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(metricCount, 2)
        let status = try await f.pendingCards.card(id: pending[0].id)?.status
        XCTAssertEqual(status, "resolved")
        XCTAssertNil(try await f.scheduler.pending()[notifyId])
    }

    /// 病历页 → 就诊卡确认写 encounter 并挂接文档
    func test_encounterCardLinksDocument() async throws {
        let f = try await makeFixture(lines: ["门诊病历", "日期：2026-09-01", "科室：心内科", "诊断：高血压 2 级", "处理：低盐饮食"])
        var draft = try XCTUnwrap(await f.docs.prepareImageDraft(patientId: f.patient, originalData: Data([1]), processedData: Data([1, 2]),
                                                                  mimeType: "image/png", docType: nil, title: nil, isSensitive: true, origin: "camera"))
        XCTAssertEqual(draft.documentTypeKey, "outpatient_record")
        XCTAssertEqual(draft.entityCards.map(\.kind), ["encounter"])
        draft.confirmationSet.confirmAllRemaining()
        await f.docs.commitDraft(draft)
        let card = try XCTUnwrap(f.docs.currentEntityCard)
        XCTAssertTrue(await f.docs.confirmEntityCard(card, confirmed: card))
        let linked = try await f.store.writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT e.department, e.diagnosis_text, d.encounter_id FROM encounter e
                JOIN document_file d ON d.encounter_id = e.id LIMIT 1
                """)
        }
        XCTAssertEqual(linked?["department"] as String?, "心内科")
        XCTAssertEqual(linked?["diagnosis_text"] as String?, "高血压 2 级")
    }

    /// 处方文档：文档卡即处方卡（既有处方写入路径），不再生成第二张处方实体卡
    func test_prescriptionDocumentDoesNotDuplicatePrescriptionCard() async throws {
        let f = try await makeFixture(lines: ["处方", "阿莫西林胶囊 0.25g", "用法：每日三次 口服", "2026-09-01"])
        let draft = try XCTUnwrap(await f.docs.prepareImageDraft(patientId: f.patient, originalData: Data([1]), processedData: Data([1, 2]),
                                                                  mimeType: "image/png", docType: nil, title: nil, isSensitive: true, origin: "camera"))
        XCTAssertTrue(draft.isPrescription)
        XCTAssertFalse(draft.entityCards.contains { $0.kind == "prescription" })
    }

    /// 队列级「剩余全部稍后处理」：每张卡各入待办
    func test_deferRemainingQueuesAllCards() async throws {
        let f = try await makeFixture(lines: ["门诊病历", "日期：2026-09-01", "科室：心内科", "诊断：高血压", "血压 140 mmHg"])
        var draft = try XCTUnwrap(await f.docs.prepareImageDraft(patientId: f.patient, originalData: Data([1]), processedData: Data([1, 2]),
                                                                  mimeType: "image/png", docType: nil, title: nil, isSensitive: true, origin: "camera"))
        draft.confirmationSet.confirmAllRemaining()
        await f.docs.commitDraft(draft)
        let count = f.docs.entityQueue.count
        XCTAssertGreaterThanOrEqual(count, 1)
        await f.docs.deferRemainingEntityCards()
        XCTAssertTrue(f.docs.entityQueue.isEmpty)
        XCTAssertEqual(try await f.pendingCards.list(patientId: f.patient).count, count)
    }
}
