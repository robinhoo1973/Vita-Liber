import UIKit
import PDFKit

/// 聊天多附件合并（2026-10-23 业主）：图片与 PDF 按选择顺序合成**一份多页 PDF**，
/// 后续只走一次 OCR 会话——同一单据的跨页共用字段与卡级结果得以归并，
/// 而不是每张图各成一份互不相干的档案。
///
/// 平台框架 only（PDFKit + CoreGraphics），零第三方依赖、零网络。
/// 页面上限 30（与 PDF 导入的 50 页上限同族，避免一次选择耗尽识别预算）。
enum ChatAttachmentMerger {
    enum Payload {
        case image(UIImage)
        case pdf(PDFDocument)
    }

    struct Output {
        let data: Data
        let pageCount: Int
        let containsPDF: Bool
        /// 超过页数上限时为 true——调用方必须如实提示，不得静默丢页。
        let truncated: Bool
    }

    /// A4 纵向；横图/横版 PDF 页等比缩入，不裁切。
    private static let pageSize = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 24
    /// 与 PDF 导入的 50 页 OCR 上限同源。
    private static let maxPages = 50

    @MainActor
    static func merge(_ payloads: [Payload]) -> Output? {
        guard !payloads.isEmpty else { return nil }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let content = mediaBox.insetBy(dx: margin, dy: margin)
        var pages = 0
        var containsPDF = false
        var truncated = false

        for payload in payloads {
            if pages >= maxPages { truncated = true; break }
            switch payload {
            case .image(let image):
                let normalized = normalizedImage(image)
                guard let cgImage = normalized.cgImage else { continue }
                let rect = aspectFit(CGSize(width: cgImage.width, height: cgImage.height), into: content)
                context.beginPDFPage(nil)
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(cgImage, in: CGRect(origin: .zero, size: rect.size))
                context.restoreGState()
                context.endPDFPage()
                pages += 1

            case .pdf(let document):
                containsPDF = true
                for index in 0..<document.pageCount {
                    if pages >= maxPages { truncated = true; break }
                    guard let page = document.page(at: index) else { continue }
                    let bounds = page.bounds(for: PDFDisplayBox.mediaBox)
                    guard bounds.width > 0, bounds.height > 0, let pageRef = page.pageRef else { continue }
                    let rect = aspectFit(bounds.size, into: content)
                    context.beginPDFPage(nil)
                    context.saveGState()
                    context.translateBy(x: rect.minX, y: rect.minY)
                    context.scaleBy(x: rect.width / bounds.width, y: rect.height / bounds.height)
                    context.translateBy(x: -bounds.minX, y: -bounds.minY)
                    context.drawPDFPage(pageRef)
                    context.restoreGState()
                    context.endPDFPage()
                    pages += 1
                }
            }
        }

        guard pages > 0 else { return nil }
        context.closePDF()
        return Output(data: output as Data, pageCount: pages, containsPDF: containsPDF,
                      truncated: truncated)
    }

    /// UIImage 的 orientation 只有经 UIKit 绘制才生效；先归一化再取 CGImage。
    @MainActor
    private static func normalizedImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func aspectFit(_ size: CGSize, into rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2,
                      width: width, height: height)
    }
}
