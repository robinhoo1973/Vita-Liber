#if os(iOS) || os(macOS)
import Foundation
import CoreGraphics
import ImageIO
import Domain

/// `GrayscaleDecoding` 的 Apple 实现（评审修正：解码能力自 Domain/CaptureQuality
/// 迁出——Domain import 白名单 ⊆ {Foundation}（L0 [5]），原文件在 `#if os()` 内
/// 裸用 CG/ImageIO 符号，直到 macOS 编译门禁（build-testflight）首次真实编译
/// 才暴露 "cannot find 'CGImageSourceCreateWithData' in scope"。
///
/// 按架构规则 3：系统服务协议注入，实现落 Infrastructure；Domain 只留纯计算。
public struct GrayscaleImageDecoder: GrayscaleDecoding {
    public init() {}

    /// 用 ImageIO 降采样解码为灰度位图（kCGImageSourceCreateThumbnailWithTransform
    /// 保留 EXIF 方向；短边对齐 maxDimension）。
    public func decode(_ data: Data, maxDimension: Int) throws -> GrayscaleImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else {
            throw ImageDecodeError.corruptData
        }
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { throw ImageDecodeError.corruptData }
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ImageDecodeError.corruptData
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return GrayscaleImage(width: w, height: h, buffer: buf)
    }
}
#endif
