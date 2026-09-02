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
        let originalSize = Size(width: cg.width, height: cg.height)
        let pngData = try encodeToPNG(cg)
        return DecodedImage(bitmapData: pngData, originalSize: originalSize, maxDimension: maxDimension)
    }

    public func decodePDF(_ data: Data, scale: Double, maxPages: Int) async throws -> [DecodedPage] {
        guard let provider = CGDataProvider(data: data as CFData),
              let pdf = CGPDFDocument(provider) else { throw DecodeError.corruptData }

        let pageCount = min(pdf.numberOfPages, maxPages)
        guard pageCount > 0 else { throw DecodeError.pageIndexOutOfBounds }

        var pages: [DecodedPage] = []
        pages.reserveCapacity(pageCount)

        for i in 1...pageCount {
            guard let page = pdf.page(at: i) else { throw DecodeError.renderFailed }
            let pageRect = page.getBoxRect(.mediaBox)
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
            let originalSize = Size(width: pageRect.width, height: pageRect.height)
            pages.append(DecodedPage(pageIndex: i-1, bitmapData: pngData,
                                     originalSize: originalSize, scale: scale))
        }
        return pages
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