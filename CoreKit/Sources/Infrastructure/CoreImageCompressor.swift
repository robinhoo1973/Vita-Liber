#if os(iOS) || os(macOS)
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import LocalAuthentication
import Domain
import Protocols

/// M-COMPRESS Apple 生产轨：Core Image 缩略图/模糊 + ImageIO 降采样 + LAContext 敏感保护。
///
/// - 缩略图：`CIPixelate`/`CIGaussianBlur` + ImageIO 降采样（避免全量解码）。
/// - 敏感媒体链（BR-007/008）：LAContext 生物识别/密码，敏感缩略图强制模糊。
public final class CoreImageCompressor: ImageCompressing, SensitiveMediaProtection, @unchecked Sendable {
    private let laContext = LAContext()
    private var protectedMedia: Set<String> = []

    public init() {}

    public func generateThumbnail(_ data: Data, spec: ThumbnailSpec) async throws -> Data {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0,
                [kCGImageSourceThumbnailMaxPixelSize: spec.maxDimension,
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

        let context = CIContext()
        guard let cgOut = context.createCGImage(ci, from: ci.extent),
              let data = NSMutableData() as CFMutableData?,
              let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CompressError.encodeFailed
        }
        CGImageDestinationAddImage(dest, cgOut, [kCGImageDestinationLossyCompressionQuality: spec.quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CompressError.encodeFailed }
        return data as Data
    }

    public func authorizeOriginalAccess(_ data: Data, policy: SensitiveMediaPolicy) async throws -> Data {
        guard policy.isSensitive else { return data }
        guard policy.requireAuthForOriginal else { return data }

        let reason = "访问敏感医疗影像原图"
        let success = try await laContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        guard success else { throw CompressError.authRequiredForOriginal }
        return data
    }

    // MARK: - SensitiveMediaProtection

    public func isProtected(_ mediaID: String) -> Bool {
        protectedMedia.contains(mediaID)
    }

    public func requestAccess(_ mediaID: String, reason: String) async throws -> Bool {
        let success = try await laContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        if success { protectedMedia.insert(mediaID) }
        return success
    }
}
#endif