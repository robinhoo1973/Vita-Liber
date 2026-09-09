#if os(iOS) || os(macOS)
import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Domain
import Protocols

/// Swift 6 收敛：@Sendable 逐页回调的串行累加器（decodePDFPages 逐页 await
/// 回调、串行执行，无并发写——mutate 捕获 var 在 Swift 6 语言模式转硬错误）。
final class PageAccumulator: @unchecked Sendable {
    var pages: [DecodedPage] = []
}

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
                 kCGImageSourceCreateThumbnailFromImageAlways: true,
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
        // Swift 6 收敛：@Sendable 回调内禁改捕获 var——经串行累加器收集
        let box = PageAccumulator()
        try await decodePDFPages(data, scale: scale, maxPages: maxPages) { page in
            box.pages.append(page)
        }
        return box.pages
    }

    /// 逐页流式渲染（审查修复）：单页渲染→回调→释放，页位图不再全部驻留内存
    /// （50 页 A4 @2x ≈ 数百 MB 的峰值内存 → 单页峰值 ≈ 数十 MB）。
    /// 单页渲染失败上抛（FR6.6 绝不静默）；调用方经 do/catch 决定继续或终止。
    public func decodePDFPages(_ data: Data, scale: Double, maxPages: Int,
                               onPage consume: @escaping @Sendable (DecodedPage) async throws -> Void) async throws {
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
            guard max(pageRect.width, pageRect.height) * scale <= 5000 else {
                throw DecodeError.renderFailed
            }
            // 审查修复：/Rotate 未应用——横放扫描页（rotation 90/270）此前
            // 渲染为侧躺/裁切，OCR 读旋转文本、逐卡确认全页作废。按旋转角
            // 换轴，经 getDrawingTransform 把页面空间正投影到位图。
            let rotation = page.rotationAngle
            let landscape = rotation == 90 || rotation == 270
            let targetWidth = Int((landscape ? pageRect.height : pageRect.width) * scale)
            let targetHeight = Int((landscape ? pageRect.width : pageRect.height) * scale)

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bytesPerRow = targetWidth * 4
            var bitmapData = Data(count: targetHeight * bytesPerRow)
            bitmapData.withUnsafeMutableBytes { ptr in
                guard let ctx = CGContext(data: ptr.baseAddress, width: targetWidth, height: targetHeight,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.interpolationQuality = .high
                let transform = page.getDrawingTransform(
                    .mediaBox,
                    rect: CGRect(x: 0, y: 0, width: CGFloat(targetWidth), height: CGFloat(targetHeight)),
                    rotate: rotation, preserveAspectRatio: true)
                ctx.concatenate(transform)
                ctx.drawPDFPage(page)
            }

            let pngData = try encodeToPNGFromData(bitmapData, width: targetWidth, height: targetHeight)
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