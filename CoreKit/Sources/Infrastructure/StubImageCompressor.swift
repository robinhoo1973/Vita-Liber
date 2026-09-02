#if os(Linux)
import Foundation
import Domain
import Protocols

/// M-COMPRESS Linux/dev 兜底：占位（保证 Linux 构建/测试可跑）。
///
/// 真实 Linux 环境如需真实缩略图，可接入 ImageMagick/vips 或纯 Swift 实现。
/// 仅作 Linux 构建/测试兜底，不进生产。
/// 注意：此类不满足严格 Sendable（测试占位），生产请使用 CoreImageCompressor。
public final class StubImageCompressor: ImageCompressing, SensitiveMediaProtection, @unchecked Sendable {
    private var protectedMedia: Set<String> = []

    public init() {}

    public func generateThumbnail(_ data: Data, spec: ThumbnailSpec) async throws -> Data {
        // 占位：返回 1x1 透明 PNG
        let png = Self.transparentPNG()
        return png
    }

    public func authorizeOriginalAccess(_ data: Data, policy: SensitiveMediaPolicy) async throws -> Data {
        // Linux 无 LAContext，直接返回或抛错
        if policy.isSensitive && policy.requireAuthForOriginal {
            throw CompressError.authRequiredForOriginal
        }
        return data
    }

    public func isProtected(_ mediaID: String) -> Bool {
        protectedMedia.contains(mediaID)
    }

    public func requestAccess(_ mediaID: String, reason: String) async throws -> Bool {
        // Linux 无生物识别，占位总是成功并记录
        protectedMedia.insert(mediaID)
        return true
    }

    private static func transparentPNG() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") ?? Data()
    }
}
#endif