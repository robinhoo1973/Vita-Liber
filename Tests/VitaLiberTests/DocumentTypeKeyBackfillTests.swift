import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
@testable import VitaLiber

/// v27 子项目 J · 原 D3-2：`doc_type_key` 首启回填——旧本地化标签三语反查稳定键 / 未命中 custom / 幂等编排。
/// 纯 App 逻辑（读写经注入闭包）+ 真实仓路径（`DocumentStore.documentsMissingTypeKey` / `setDocTypeKey`，内存库）；
/// 三语 .strings 随测试宿主 bundle 载入。
@MainActor
// binds: SU-M2-PENDINGCARD（FR5.5 文档类型稳定键 · 原 D3-2；TC 登记 J5）
final class DocumentTypeKeyBackfillTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "DocumentTypeKeyBackfillTests." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// 两成员 + 文档仓（真实仓路径用例共用）。
    private func storeFixture() async throws -> (GRDBStore, DocumentStore, UUID, UUID) {
        let store = try GRDBStore.inMemory()
        let (a, b) = (UUID(), UUID())
        try await store.writer.write { db in
            for id in [a, b] {
                try db.execute(sql: """
                    INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                    VALUES (?, 'M', '本人', 0, 0)
                    """, arguments: [id.uuidString])
            }
        }
        return (store, DocumentStore(writer: store.writer), a, b)
    }

    private func legacySave(_ docs: DocumentStore, patient: UUID, label: String, sha: String) async throws -> UUID {
        try await docs.save(patientId: patient, docType: label, sha256: sha, mimeType: "image/jpeg",
                            origin: "import", isSensitive: false, metaJSON: nil, title: nil)
    }

    /// 原名：test_旧标签反查_三语_未命中custom_已是键者直通
    func test_legacyLabelLookup_threeLanguages_missBecomesCustom_existingKeyPassesThrough() {
        // 三语旧标签（docTypeLabel.* 15 键）→ DocumentTypeKey.legacyLabelKeys
        XCTAssertEqual(DocumentTypeKeyBackfill.resolve(label: "处方单"), .prescription)
        XCTAssertEqual(DocumentTypeKeyBackfill.resolve(label: "影像报告"), .examReport)
        XCTAssertEqual(DocumentTypeKeyBackfill.resolve(label: "體檢報告"), .checkupReport)
        XCTAssertEqual(DocumentTypeKeyBackfill.resolve(label: "Discharge summary"), .dischargeSummary)
        XCTAssertEqual(DocumentTypeKeyBackfill.resolve(label: "缴费单"), .invoice)
        // 曾作为标签写库的非 docTypeLabel.* 键（doc.type.report / claim.type.invoice）
        XCTAssertEqual(DocumentTypeKeyBackfill.resolve(label: "检验报告"), .labReport)
        XCTAssertEqual(DocumentTypeKeyBackfill.resolve(label: "发票"), .invoice)
        // 新 27 键标签（当前语言）
        XCTAssertEqual(DocumentTypeKeyBackfill.resolve(label: L10n.docTypeName(.anesthesiaRecord)), .anesthesiaRecord)
        // 已存了键 / 旧标签键的行直通
        XCTAssertEqual(DocumentTypeKeyBackfill.resolve(label: "lab_report"), .labReport)
        XCTAssertEqual(DocumentTypeKeyBackfill.resolve(label: "imageReport"), .examReport)
        // 未命中不猜
        XCTAssertEqual(DocumentTypeKeyBackfill.resolve(label: "随手拍的纸条"), .custom)
        XCTAssertEqual(DocumentTypeKeyBackfill.resolve(label: "   "), .custom)
    }

    /// 原名：test_编排_幂等_成功置标记_失败不置标记且下次重试
    func test_orchestration_idempotent_successSetsMarker_failureLeavesMarkerForRetry() async {
        let ud = defaults()
        let rows = [DocumentTypeKeyBackfill.Row(id: UUID(), patientId: UUID(), docType: "处方单"),
                    DocumentTypeKeyBackfill.Row(id: UUID(), patientId: UUID(), docType: "未知类型")]
        var applied: [(UUID, DocumentTypeKey)] = []
        struct Boom: Error {}

        // 首次：第二行写入失败 → 未置标记，已写 1 行
        let failed = await DocumentTypeKeyBackfill.runIfNeeded(defaults: ud, pending: { rows }) { id, _, key in
            if key == .custom { throw Boom() }
            applied.append((id, key))
        }
        XCTAssertEqual(failed, .failed(written: 1))
        XCTAssertFalse(ud.bool(forKey: DocumentTypeKeyBackfill.doneKey))
        XCTAssertEqual(applied.map(\.1), [.prescription])

        // 重试：只剩未写行（IS NULL 谓词由 store 承担，此处模拟 pending 缩小），全部成功 → 置标记
        let completed = await DocumentTypeKeyBackfill.runIfNeeded(defaults: ud, pending: { [rows[1]] }) { id, _, key in
            applied.append((id, key))
        }
        XCTAssertEqual(completed, .completed(1))
        XCTAssertTrue(ud.bool(forKey: DocumentTypeKeyBackfill.doneKey))
        XCTAssertEqual(applied.map(\.1), [.prescription, .custom])

        // 再启动：零访问
        var touched = false
        let skipped = await DocumentTypeKeyBackfill.runIfNeeded(defaults: ud, pending: { touched = true; return rows }) { _, _, _ in touched = true }
        XCTAssertEqual(skipped, .alreadyDone)
        XCTAssertFalse(touched)
    }

    /// 真实仓路径：跨成员旧行（键 NULL）按标签回填 / 未命中 custom；新入库已带键的行不进清单、不被改写；
    /// `batchLimit` 小于待回填行数时分批直至清单为空（不留尾巴）；完成置标记、再启动零访问。
    /// 原名：test_真实仓_旧行回填_带键新行不动_分批_幂等
    func test_realStore_oldRowsBackfilled_keyedRowsUntouched_batched_idempotent() async throws {
        let ud = defaults()
        let (_, docs, a, b) = try await storeFixture()
        let rx = try await legacySave(docs, patient: a, label: "处方单", sha: "b1")
        let exam = try await legacySave(docs, patient: b, label: "影像报告", sha: "b2")
        let unknown = try await legacySave(docs, patient: b, label: "随手拍的纸条", sha: "b3")
        let keyed = try await docs.save(patientId: b, docType: L10n.docTypeName(.labReport), sha256: "b4", mimeType: "image/jpeg",
                                        origin: "import", isSensitive: false, metaJSON: nil, title: nil,
                                        docTypeKey: DocumentTypeKey.labReport.rawValue)

        let outcome = await DocumentTypeKeyBackfill.runIfNeeded(store: docs, defaults: ud, batchLimit: 2)
        XCTAssertEqual(outcome, .completed(3), "3 行旧数据分两批（2+1）全部回填")
        XCTAssertTrue(ud.bool(forKey: DocumentTypeKeyBackfill.doneKey))
        let rxRow = try await docs.fetch(id: rx)
        XCTAssertEqual(rxRow?.docTypeKey, DocumentTypeKey.prescription.rawValue)
        let examRow = try await docs.fetch(id: exam)
        XCTAssertEqual(examRow?.docTypeKey, DocumentTypeKey.examReport.rawValue, "旧 15 标签三语反查")
        let unknownRow = try await docs.fetch(id: unknown)
        XCTAssertEqual(unknownRow?.docTypeKey, DocumentTypeKey.custom.rawValue, "未命中不猜 = custom")
        let keyedRow = try await docs.fetch(id: keyed)
        XCTAssertEqual(keyedRow?.docTypeKey, DocumentTypeKey.labReport.rawValue, "入库即带键的行不被回填触碰")
        let remaining = try await docs.documentsMissingTypeKey(patientId: nil, limit: 10)
        XCTAssertTrue(remaining.isEmpty)

        let again = await DocumentTypeKeyBackfill.runIfNeeded(store: docs, defaults: ud)
        XCTAssertEqual(again, .alreadyDone)
    }

    /// 真实仓路径：某行写入失败（以触发器模拟）→ 未置标记、已写行保留；故障消除后再启动只补剩余行并完成。
    /// 原名：test_真实仓_写失败不置标记_修复后重试补齐
    func test_realStore_writeFailureLeavesMarker_retryAfterFixCompletes() async throws {
        let ud = defaults()
        let (store, docs, a, _) = try await storeFixture()
        let first = try await legacySave(docs, patient: a, label: "处方单", sha: "f1")
        let second = try await legacySave(docs, patient: a, label: "检验报告", sha: "f2")
        // 第二行的键写入被拒（按 created_at 序：save 用同一时刻内的 Date()，以 id 钉住目标行）
        try await store.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_second_key BEFORE UPDATE OF doc_type_key ON document_file
                WHEN NEW.id = '\(second.uuidString)' BEGIN SELECT RAISE(ABORT, 'key write rejected'); END
                """)
        }
        let failed = await DocumentTypeKeyBackfill.runIfNeeded(store: docs, defaults: ud, batchLimit: 1)
        guard case .failed(let written) = failed else { return XCTFail("写失败必须返回 .failed，实际 \(failed)") }
        XCTAssertLessThanOrEqual(written, 1)
        XCTAssertFalse(ud.bool(forKey: DocumentTypeKeyBackfill.doneKey), "任一行失败不置完成标记")
        let secondRow = try await docs.fetch(id: second)
        XCTAssertNil(secondRow?.docTypeKey)

        try await store.writer.write { db in try db.execute(sql: "DROP TRIGGER reject_second_key") }
        let retried = await DocumentTypeKeyBackfill.runIfNeeded(store: docs, defaults: ud, batchLimit: 1)
        XCTAssertEqual(retried, .completed(2 - written), "重试只补未写行（IS NULL 谓词）")
        XCTAssertTrue(ud.bool(forKey: DocumentTypeKeyBackfill.doneKey))
        let firstRow = try await docs.fetch(id: first)
        XCTAssertEqual(firstRow?.docTypeKey, DocumentTypeKey.prescription.rawValue)
        let secondAfter = try await docs.fetch(id: second)
        XCTAssertEqual(secondAfter?.docTypeKey, DocumentTypeKey.labReport.rawValue)
    }
}
