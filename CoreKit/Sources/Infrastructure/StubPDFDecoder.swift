#if os(Linux)
import Foundation
import Domain
import Protocols

/// M-DECODE Linux/dev 兜底：无 PDFium 依赖，返回占位（保证 Linux 构建/测试可跑）。
///
/// 真实 Linux 环境如需真实 PDF 解码，可接入 PDFium（BSD，Chrome 同源）。
/// 仅作 Linux 构建/测试兜底，不进生产。
public struct StubPDFDecoder: ImageDecoding {
    public init() {}

    public func decodeImage(_ data: Data, maxDimension: Int) async throws -> DecodedImage {
        // 占位：返回 1x1 透明 PNG
        let png = Self.transparentPNG()
        return DecodedImage(bitmapData: png, originalSize: Size(width: 1, height: 1), maxDimension: maxDimension)
    }

    public func decodePDF(_ data: Data, scale: Double, maxPages: Int) async throws -> [DecodedPage] {
        // 占位：返回 1 页空白
        let png = Self.transparentPNG()
        let page = DecodedPage(pageIndex: 0, bitmapData: png,
                               originalSize: Size(width: 595, height: 842), scale: scale)
        return [page]
    }

    private static func transparentPNG() -> Data {
        // 1x1 透明 PNG（base64: iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==）
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") ?? Data()
    }
}
#endif