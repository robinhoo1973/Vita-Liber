import Testing
import UIKit
import PDFKit
import Domain
@testable import VitaLiber

/// 多附件合并文档的跨页共用字段归并（2026-10-23 业主「OCR 融会贯通」）。
/// 规则：同键值唯一才补齐；冲突不猜；补入字段无原文锚点、置信封顶 0.5、D 级。
@MainActor
@Suite("跨页共用字段归并")
struct CrossPageConsolidationTests {
    private func page(_ index: Int, _ fields: [FieldDraft]) -> DocumentsState.PageAnalysis {
        DocumentsState.PageAnalysis(index: index, lines: [], fields: fields)
    }

    private func card(pageIndex: Int) -> MatchedCard {
        MatchedCard(kind: "metric_sample", pageIndex: pageIndex, shared: [], rows: [],
                    allFieldCoverage: 1, requiredCoverage: 1,
                    missingRequired: [], level: .complete)
    }

    @Test("唯一表头值补齐到后续页卡")
    func uniqueHeaderFillsLaterCard() {
        let pages = [
            page(0, [
                FieldDraft(key: "hospital", value: "协和医院", confidence: 0.9,
                           rawText: "协和医院", grade: .ocrUnconfirmed),
                FieldDraft(key: "report_date", value: "2026-01-02", confidence: 0.9,
                           rawText: "2026-01-02", grade: .ocrUnconfirmed),
            ]),
            page(1, []),
        ]
        let shared = DocumentsState.crossPageSharedFields(pages: pages)
        #expect(shared["hospital"]?.value == "协和医院")
        #expect(shared["report_date"]?.value == "2026-01-02")

        let merged = DocumentsState.applyingCrossPageShared([card(pageIndex: 1)], pages: pages)
        let hospital = merged[0].shared.first { $0.key == "hospital" }
        #expect(hospital?.value == "协和医院")
        #expect(hospital?.rawText == nil)
        #expect(hospital?.sourceLineIndex == nil)
        #expect(hospital?.confidence == 0.5)
        #expect(hospital?.grade == .ocrUnconfirmed)
        #expect(merged[0].shared.first { $0.key == "measured_at" }?.value == "2026-01-02")
    }

    @Test("同键不同值视为不同单据，不合并")
    func conflictingValuesAreNotMerged() {
        let pages = [
            page(0, [FieldDraft(key: "hospital", value: "协和医院", confidence: 0.9,
                                rawText: "协和医院", grade: .ocrUnconfirmed)]),
            page(1, [FieldDraft(key: "hospital", value: "市一医院", confidence: 0.9,
                                rawText: "市一医院", grade: .ocrUnconfirmed)]),
        ]
        #expect(DocumentsState.crossPageSharedFields(pages: pages).isEmpty)
        let merged = DocumentsState.applyingCrossPageShared([card(pageIndex: 1)], pages: pages)
        #expect(merged[0].shared.isEmpty)
    }

    @Test("单页文档不触发跨页补齐")
    func singlePageIsUntouched() {
        let pages = [
            page(0, [FieldDraft(key: "hospital", value: "协和医院", confidence: 0.9,
                                rawText: "协和医院", grade: .ocrUnconfirmed)]),
        ]
        #expect(DocumentsState.crossPageSharedFields(pages: pages).isEmpty)
    }

    @Test("多附件按选择顺序合并为一份多页 PDF")
    func mergePreservesOrderAndPages() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
            .pdfData { context in
                context.beginPage()
                UIColor.white.setFill()
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            }
        let pdf = try #require(PDFDocument(data: pdfData))

        let output = ChatAttachmentMerger.merge([
            .image(image), .pdf(pdf), .image(image),
        ])
        #expect(output?.pageCount == 3)
        #expect(output?.truncated == false)
        #expect(output?.data.starts(with: Data("%PDF".utf8)) == true)
    }

    @Test("超过 50 页截断并如实标记")
    func mergeMarksTruncation() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let output = ChatAttachmentMerger.merge(Array(repeating: .image(image), count: 51))
        #expect(output?.pageCount == 50)
        #expect(output?.truncated == true)
    }
}
