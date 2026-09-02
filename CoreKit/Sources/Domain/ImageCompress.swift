import Foundation

/// §2.2 / §5.10 / M-COMPRESS：缩略图/模糊与敏感脱敏 Domain 类型。

/// 缩略图规格。
public struct ThumbnailSpec: Sendable, Equatable, Codable {
    /// 目标最大边长（像素）。
    public var maxDimension: Int
    /// 模糊半径（0 为不模糊，>0 高斯模糊，用于敏感缩略图）。
    public var blurRadius: Double
    /// 质量（JPEG 0..1）。
    public var quality: Double

    public init(maxDimension: Int = 320, blurRadius: Double = 0, quality: Double = 0.7) {
        self.maxDimension = maxDimension; self.blurRadius = blurRadius; self.quality = quality
    }
}

/// 敏感媒体策略（BR-007/008）。
public struct SensitiveMediaPolicy: Sendable, Equatable, Codable {
    /// 是否标记为敏感（如病理切片、隐私部位、身份证件）。
    public var isSensitive: Bool
    /// 敏感原图查看是否需要二次认证（FaceID/密码）。
    public var requireAuthForOriginal: Bool
    /// 敏感缩略图是否强制模糊（blurRadius > 0）。
    public var forceBlurThumbnail: Bool

    public init(isSensitive: Bool = false, requireAuthForOriginal: Bool = true, forceBlurThumbnail: Bool = true) {
        self.isSensitive = isSensitive
        self.requireAuthForOriginal = requireAuthForOriginal
        self.forceBlurThumbnail = forceBlurThumbnail
    }
}

/// 压缩/缩略图错误。
public enum CompressError: Error, Sendable, Equatable {
    case encodeFailed
    case decodeFailed
    case authRequiredForOriginal
    case sensitiveMediaBlocked
}

/// 压缩/缩略图协议（跨平台统一接口）。
public protocol ImageCompressing: Sendable {
    /// 生成缩略图（可选模糊，用于敏感媒体）。
    func generateThumbnail(_ data: Data, spec: ThumbnailSpec) async throws -> Data
    /// 敏感媒体保护链：查看原图需鉴权（BR-007/008）。
    func authorizeOriginalAccess(_ data: Data, policy: SensitiveMediaPolicy) async throws -> Data
}

/// 敏感媒体保护链（BR-007/008 独立抽象，供上层调用）。
public protocol SensitiveMediaProtection: Sendable {
    /// 判断媒体是否受保护。
    func isProtected(_ mediaID: String) -> Bool
    /// 请求访问敏感原图（需生物识别/密码）。
    func requestAccess(_ mediaID: String, reason: String) async throws -> Bool
}