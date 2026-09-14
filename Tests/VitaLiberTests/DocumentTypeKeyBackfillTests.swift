import XCTest
import Foundation
import Domain
@testable import VitaLiber

/// v27 子项目 J · 原 D3-2：`doc_type_key` 首启回填——旧本地化标签三语反查稳定键 / 未命中 custom / 幂等编排。
/// 纯 App 逻辑（读写经注入闭包）；三语 .strings 随测试宿主 bundle 载入。
@MainActor
// binds: SU-M2-PENDINGCARD（FR5.5 文档类型稳定键 · 原 D3-2；TC 登记 J5）
final class DocumentTypeKeyBackfillTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "DocumentTypeKeyBackfillTests." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func test_旧标签反查_三语_未命中custom_已是键者直通() {
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

    func test_编排_幂等_成功置标记_失败不置标记且下次重试() async {
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
}
