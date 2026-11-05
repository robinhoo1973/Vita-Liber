#if os(iOS) || os(macOS)
// linux-blind: CoreGraphics/ImageIO 仅在 Apple 切片；Linux 无第三 OCR 源。
import Foundation
import CoreGraphics
import Domain

/// CnOCR（doc-densenet_lite_136-gru）行预处理：按 Paddle det 框裁剪 → 高 32、
/// 等比宽、单通道灰度、[0,1]。参数来自 `Resources/OCRModels/catalog.json` 的 `third`。
///
/// 与 `PaddleRecPreprocessor` 分开：Paddle 是 48 高、BGR、[-1,1]；CnOCR 是
/// 32 高、灰度、[0,1]。共用同一坐标系（不应用 EXIF 旋转），与 Vision 行框一致。
public enum CnOCRPreprocessor {
    public struct Prepared: Sendable, Equatable {
        public var tensor: [Float]
        public var width: Int
        public var cropWidth: Double
        public var cropHeight: Double
    }

    public static func prepare(page: PaddleRecPreprocessor.Page, bbox: LayoutRect,
                               height: Int = 32, maxWidth: Int = 4096,
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
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: width, height: cropHeight)),
              cropped.height > 0 else { return nil }

        let aspect = Double(cropped.width) / Double(cropped.height)
        let targetWidth = max(8, Int((Double(height) * aspect).rounded()))
        // 超宽行不压扁（压扁会系统性改变字宽，第三源反而制造噪声）；直接跳过。
        guard targetWidth <= maxWidth else { return nil }

        var pixels = [UInt8](repeating: 255, count: targetWidth * height)
        let gray = CGColorSpaceCreateDeviceGray()
        var drew = false
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: targetWidth, height: height,
                                          bitsPerComponent: 8, bytesPerRow: targetWidth,
                                          space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            context.interpolationQuality = .high
            // 文档行以白底黑字为主；透明/未绘制区域补白，与 CnOCR 训练分布一致。
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: height))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: targetWidth, height: height))
            drew = true
        }
        guard drew else { return nil }

        var tensor = [Float](repeating: 0, count: targetWidth * height)
        for index in 0..<tensor.count {
            tensor[index] = Float(pixels[index]) / 255
        }
        return Prepared(tensor: tensor, width: targetWidth,
                        cropWidth: Double(cropped.width), cropHeight: Double(cropped.height))
    }
}
#endif
