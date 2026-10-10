#if os(iOS) || os(macOS)
// linux-blind: CoreImage 图像处理 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Domain
import Protocols

/// M-COMPRESS Apple 生产轨：Core Image 缩略图/模糊 + ImageIO 降采样。
///
/// - 缩略图：`CIPixelate`/`CIGaussianBlur` + ImageIO 降采样（避免全量解码）。
/// - 敏感媒体链（BR-007/008）：敏感缩略图强制模糊；解锁门在 App 层
///   （SensitiveMediaContainer/SensitiveMediaOriginalView + LocalAuthGateUnlocker），
///   本文件不再持 LAContext 出口（收口批D 死抽象清除）。
public final class CoreImageCompressor: ImageCompressing, @unchecked Sendable {
    private static let sharedContext = CIContext()

    public init() {}

    public func generateThumbnail(_ data: Data, spec: ThumbnailSpec) async throws -> Data {
        // 第九轮审查修复（P1，API 语义错配）：原用 CGImageSourceCreateImageAtIndex
        // 却传入 thumbnailing 选项——`kCGImageSourceThumbnailMaxPixelSize` /
        // `...CreateThumbnailWithTransform` / `...CreateThumbnailFromImageAlways`
        // **仅**被 CGImageSourceCreateThumbnailAtIndex 识别，前者会静默忽略它们：
        // 320px 降采样与 EXIF 方向校正都不生效，对 12MP 原图做全尺寸解码，
        // BR-007 锁定态的模糊半径相对整图退化为 0.3%（近可读），模糊 JPEG
        // 体积/内存峰值也放大 ~12 倍。改用缩略图 API（三个选项全在此生效）。
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0,
                [kCGImageSourceThumbnailMaxPixelSize: spec.maxDimension,
                 kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw CompressError.decodeFailed
        }

        var ci = CIImage(cgImage: cg)
        if spec.blurRadius > 0 {
            guard let filter = CIFilter(name: "CIGaussianBlur") else { throw CompressError.encodeFailed }
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(spec.blurRadius, forKey: kCIInputRadiusKey)
            ci = filter.outputImage ?? ci
        }

        // 共享 CIContext（GPU 上下文创建成本高；CIContext 线程安全可跨调用
        // 复用——第四轮全仓审查效率修复，与 VisionImagePreprocessor 同纪律）
        let context = Self.sharedContext
        guard let cgOut = context.createCGImage(ci, from: ci.extent),
              let data = NSMutableData() as CFMutableData?,
              let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CompressError.encodeFailed
        }
        CGImageDestinationAddImage(dest, cgOut, [kCGImageDestinationLossyCompressionQuality: spec.quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CompressError.encodeFailed }
        return data as Data
    }

}
#endif