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
        // 附件起始页：图 0 / PDF 1 / 图 2（2026-10-30 页偏移语义）。
        #expect(output?.attachmentOffsets == [0, 1, 2])
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
        // 截断后只保留真实落页的附件（第 51 张无页）。
        #expect(output?.attachmentOffsets.count == 50)
    }

    // MARK: - 方向（2026-10-30 业主问题 3：合并导入后上下颠倒）

    /// 上红下蓝的 8×8 探针图（UIKit 坐标：y=0 为顶）。
    private func uprightProbeImage() -> UIImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8),
                                       format: format).image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 4, width: 8, height: 4))
        }
    }

    /// 按图像内相对坐标取样单像素（0…255）。
    private func rgb(in image: UIImage, xFraction: CGFloat,
                     yFraction: CGFloat) -> (red: Int, green: Int, blue: Int) {
        let point = CGPoint(x: image.size.width * xFraction,
                            y: image.size.height * yFraction)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let sample = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1),
                                             format: format).image { _ in
            image.draw(at: CGPoint(x: -point.x, y: -point.y))
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let cg = sample.cgImage,
              let context = CGContext(data: &bytes, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (-1, -1, -1) }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    @Test("合并 PDF 的图片页保持正立（不再上下颠倒）")
    func mergeKeepsImageUpright() throws {
        let source = try #require(uprightProbeImage())
        let output = try #require(ChatAttachmentMerger.merge([.image(source)]))
        let page = try DocumentSourceRenderer.image(
            data: output.data, mimeType: "application/pdf", pageIndex: 0)
        // 页面 A4 纵向、内容区等比缩入：图片占据垂直中段，取 0.40/0.60 两个内点。
        let top = rgb(in: page, xFraction: 0.5, yFraction: 0.40)
        let bottom = rgb(in: page, xFraction: 0.5, yFraction: 0.60)
        #expect(top.red > 200 && top.blue < 60)
        #expect(bottom.blue > 200 && bottom.red < 60)
    }

    @Test("方向元数据先合入像素再合并")
    func mergeBakesImageOrientation() throws {
        let cg = try #require(uprightProbeImage()?.cgImage)
        let flipped = UIImage(cgImage: cg, scale: 1, orientation: .down)
        let output = try #require(ChatAttachmentMerger.merge([.image(flipped)]))
        let page = try DocumentSourceRenderer.image(
            data: output.data, mimeType: "application/pdf", pageIndex: 0)
        let top = rgb(in: page, xFraction: 0.5, yFraction: 0.40)
        let bottom = rgb(in: page, xFraction: 0.5, yFraction: 0.60)
        #expect(top.blue > 200 && top.red < 60)
        #expect(bottom.red > 200 && bottom.blue < 60)
    }

    @Test("方向归一输出 .up 并保留红蓝上下关系")
    func normalizedImageBakesOrientation() throws {
        let cg = try #require(uprightProbeImage()?.cgImage)
        let flipped = UIImage(cgImage: cg, scale: 1, orientation: .down)
        let baked = MediaImport.normalizedImage(flipped)
        #expect(baked.imageOrientation == .up)
        let top = rgb(in: baked, xFraction: 0.5, yFraction: 0.25)
        let bottom = rgb(in: baked, xFraction: 0.5, yFraction: 0.75)
        #expect(top.blue > 200 && top.red < 60)
        #expect(bottom.red > 200 && bottom.blue < 60)
    }

    @Test("导入前检查顺时针旋转 90°：尺寸互换且左半转到上半")
    func rotateClockwiseSwapsSides() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        // 横版 8×4：左半红、右半蓝（UIKit 坐标，y=0 为顶）。
        let source = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 4),
                                             format: format).image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 4, y: 0, width: 4, height: 4))
        }
        let rotated = ChatImageImportPreview.rotatedClockwise(source)
        #expect(rotated.size == CGSize(width: 4, height: 8))
        let top = rgb(in: rotated, xFraction: 0.5, yFraction: 0.25)
        let bottom = rgb(in: rotated, xFraction: 0.5, yFraction: 0.75)
        #expect(top.red > 200 && top.blue < 60)
        #expect(bottom.blue > 200 && bottom.red < 60)
    }
}
