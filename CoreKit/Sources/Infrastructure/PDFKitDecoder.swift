#if os(iOS) || os(macOS)
import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Domain
import Protocols

/// M-DECODE Apple 生产轨：PDFKit 多页渲染 + ImageIO 降采样解码。
///
/// - `pdfPages(scale: 2.0, maxPages: 50)` 逐页缩略图（§5.2 C2）。
/// - `decodeDownsampled(maxDimension: 2400)` 控制最长边（§5.2 C1）。
/// - 失败上抛（FR6.6 C3）、临时 CGImage 及时释放（C4）。
public final class PDFKitDecoder: ImageDecoding, @unchecked Sendable {
    public init() {}

    public func decodeImage(_ data: Data, maxDimension: Int) async throws -> DecodedImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0,
                [kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                 kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw DecodeError.corruptData
        }
        let originalSize = Size(width: Double(cg.width), height: Double(cg.height))
        let pngData = try encodeToPNG(cg)
        return DecodedImage(bitmapData: pngData, originalSize: originalSize, maxDimension: maxDimension)
    }

    public func decodePDF(_ data: Data, scale: Double, maxPages: Int) async throws -> [DecodedPage] {
        // 兼容保留：全量路径（调用方一般用逐页流式 decodePDFPages）
        var pages: [DecodedPage] = []
        try await decodePDFPages(data, scale: scale, maxPages: maxPages) { page in
            pages.append(page)
        }
        return pages
    }

    /// 逐页流式渲染（审查修复）：单页渲染→回调→释放，页位图不再全部驻留内存
    /// （50 页 A4 @2x ≈ 数百 MB 的峰值内存 → 单页峰值 ≈ 数十 MB）。
    /// 单页渲染失败上抛（FR6.6 绝不静默）；调用方经 do/catch 决定继续或终止。
    public func decodePDFPages(_ data: Data, scale: Double, maxPages: Int,
                               _ consume: @escaping @Sendable (DecodedPage) async throws -> Void) async throws {
        guard let provider = CGDataProvider(data: data as CFData),
              let pdf = CGPDFDocument(provider) else { throw DecodeError.corruptData }

        let pageCount = min(pdf.numberOfPages, maxPages)
        guard pageCount > 0 else { throw DecodeError.pageIndexOutOfBounds }

        for i in 1...pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: i) else { throw DecodeError.renderFailed }
            let pageRect = page.getBoxRect(.mediaBox)
            // 审查修复：MediaBox 不可信（海报/超大版面或损坏 PDF）——无上限的
            // Data(count:) 分配直接 OOM。单页最长边封顶 5000pt@scale，
            // 超限视为不可渲染（FR6.6 可见失败而非崩溃）
            guard pageRect.width * scale <= 5000, pageRect.height * scale <= 5000 else {
                throw DecodeError.renderFailed
            }
            let targetWidth = pageRect.width * scale
            let targetHeight = pageRect.height * scale

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bytesPerRow = Int(targetWidth) * 4
            var bitmapData = Data(count: Int(targetHeight) * bytesPerRow)
            bitmapData.withUnsafeMutableBytes { ptr in
                guard let ctx = CGContext(data: ptr.baseAddress, width: Int(targetWidth), height: Int(targetHeight),
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.interpolationQuality = .high
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
                ctx.drawPDFPage(page)
            }

            let pngData = try encodeToPNGFromData(bitmapData, width: Int(targetWidth), height: Int(targetHeight))
            let originalSize = Size(width: Double(pageRect.width), height: Double(pageRect.height))
            try await consume(DecodedPage(pageIndex: i-1, bitmapData: pngData,
                                          originalSize: originalSize, scale: scale))
        }
    }

    // MARK: - 私有编码

    private func encodeToPNG(_ cg: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw DecodeError.renderFailed
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw DecodeError.renderFailed }
        return data as Data
    }

    private func encodeToPNGFromData(_ data: Data, width: Int, height: Int) throws -> Data {
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw DecodeError.renderFailed
        }
        return try encodeToPNG(cg)
    }
}
#endif