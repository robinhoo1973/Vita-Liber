import Foundation

/// §5.2 / §2.2 / M-DECODE：PDF→位图解码与图片降采样 Domain 类型。

/// 解码后的页面位图。
public struct DecodedPage: Sendable, Codable, Equatable {
    /// 页面索引（从 0 开始）。
    public var pageIndex: Int
    /// 位图 Data（PNG，已按 scale 降采样）。
    public var bitmapData: Data
    /// 原始页面尺寸（点）。
    public var originalSize: Size
    /// 缩放比例。
    public var scale: Double

    public init(pageIndex: Int, bitmapData: Data, originalSize: Size, scale: Double) {
        self.pageIndex = pageIndex; self.bitmapData = bitmapData
        self.originalSize = originalSize; self.scale = scale
    }
}

/// 单图解码结果（非 PDF）。
public struct DecodedImage: Sendable, Codable, Equatable {
    /// 降采样后位图 Data（PNG）。
    public var bitmapData: Data
    /// 原始尺寸。
    public var originalSize: Size
    /// 目标最大边长。
    public var maxDimension: Int

    public init(bitmapData: Data, originalSize: Size, maxDimension: Int) {
        self.bitmapData = bitmapData; self.originalSize = originalSize; self.maxDimension = maxDimension
    }
}

/// 解码错误。
public enum DecodeError: Error, Sendable, Equatable {
    case corruptData
    case unsupportedFormat
    case renderFailed
    case memoryPressure
    case pageIndexOutOfBounds
    case exceedsMaxPages
}

/// 解码协议（跨平台统一接口）。
public protocol ImageDecoding: Sendable {
    /// 解码图片（JPEG/PNG/HEIC），降采样至 maxDimension（最长边）。
    func decodeImage(_ data: Data, maxDimension: Int) async throws -> DecodedImage
    /// 解码 PDF，返回每页位图（最多 maxPages）。
    func decodePDF(_ data: Data, scale: Double, maxPages: Int) async throws -> [DecodedPage]
}