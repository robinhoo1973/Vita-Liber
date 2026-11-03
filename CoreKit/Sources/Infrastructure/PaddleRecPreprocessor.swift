#if os(iOS) || os(macOS)
// linux-blind: ImageIO/CoreGraphics 裁剪与像素重排；Linux 无图片解码链。
import Foundation
import CoreGraphics
import ImageIO
import Domain

/// PP-OCRv6 rec 预处理：按 Vision 行框裁剪 → 高 48、动态宽、BGR、[-1,1]。
/// 2026-11-03 调参批：参数全部来自 `Resources/OCRModels/catalog.json`。
public enum PaddleRecPreprocessor {
    public struct Prepared: Sendable, Equatable {
        public var tensor: [Float]
        public var width: Int
        public var cropWidth: Double
        public var cropHeight: Double
    }

    /// 一页只解码/定向一次；逐行裁剪复用同一 CGImage（避免每行重解整图）。
    public struct Page {
        public let image: CGImage
        public let width: Double
        public let height: Double
    }

    public static func page(from imageData: Data) -> Page? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = orientedImage(source: source),
              image.width > 0, image.height > 0 else { return nil }
        return Page(image: image, width: Double(image.width), height: Double(image.height))
    }

    public static func prepare(imageData: Data, bbox: LayoutRect,
                               height: Int = 48, maxWidth: Int = 3200,
                               verticalPadding: Double = 0.06,
                               horizontalPadding: Double = 0.02) -> Prepared? {
        guard let page = page(from: imageData) else { return nil }
        return prepare(page: page, bbox: bbox, height: height, maxWidth: maxWidth,
                       verticalPadding: verticalPadding, horizontalPadding: horizontalPadding)
    }

    public static func prepare(page: Page, bbox: LayoutRect,
                               height: Int = 48, maxWidth: Int = 3200,
                               verticalPadding: Double = 0.06,
                               horizontalPadding: Double = 0.02) -> Prepared? {
        guard height > 0, maxWidth > 0 else { return nil }
        let image = page.image
        let imageWidth = page.width
        let imageHeight = page.height
        guard imageWidth > 0, imageHeight > 0 else { return nil }

        let padX = bbox.width * horizontalPadding
        let padY = bbox.height * verticalPadding
        var x = (bbox.x - padX) * imageWidth
        var y = (bbox.y - padY) * imageHeight
        var width = (bbox.width + padX * 2) * imageWidth
        var cropHeight = (bbox.height + padY * 2) * imageHeight
        x = max(0, min(x, imageWidth - 1))
        y = max(0, min(y, imageHeight - 1))
        width = max(1, min(width, imageWidth - x))
        cropHeight = max(1, min(cropHeight, imageHeight - y))
        let rect = CGRect(x: x, y: y, width: width, height: cropHeight)
        guard let cropped = image.cropping(to: rect) else { return nil }

        let aspect = Double(cropped.width) / Double(cropped.height)
        let rawWidth = Int((Double(height) * aspect).rounded())
        let targetWidth = min(maxWidth, max(8, ((rawWidth + 7) / 8) * 8))
        guard targetWidth > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: targetWidth * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var drew = false
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: targetWidth, height: height,
                                          bitsPerComponent: 8, bytesPerRow: targetWidth * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
            context.interpolationQuality = .high
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: height))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: targetWidth, height: height))
            drew = true
        }
        guard drew else { return nil }

        let plane = targetWidth * height
        var tensor = [Float](repeating: 0, count: plane * 3)
        for index in 0..<plane {
            let offset = index * 4
            let r = Float(pixels[offset]) / 127.5 - 1
            let g = Float(pixels[offset + 1]) / 127.5 - 1
            let b = Float(pixels[offset + 2]) / 127.5 - 1
            tensor[index] = b
            tensor[plane + index] = g
            tensor[plane * 2 + index] = r
        }
        return Prepared(tensor: tensor, width: targetWidth,
                        cropWidth: Double(cropped.width), cropHeight: Double(cropped.height))
    }

    /// 用缩略图 API 应用 EXIF 方向；maxPixelSize 取原图长边，不主动放大。
    private static func orientedImage(source: CGImageSource) -> CGImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let maxPixel = max(width, height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
#endif
