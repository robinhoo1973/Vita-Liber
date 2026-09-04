import SwiftUI
import UIKit
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

/// 媒体导入共用件：ImageIO 下采样（§5.10 纪律——原图不整图解码进内存）
/// 与 PhotosPicker 并发加载。观察创建（F8）与资料库拍摄（F5）复用。
///
/// 并发纪律（评审修正，CI 编译红修复）：跨隔离边界只传 Sendable 值——
/// 非隔离上下文的产出为 `Data`（下采样缩略图亦为 JPEG Data），
/// `UIImage` 解码留在 MainActor 侧（小图解码 ~1-3ms，无卡顿）。
enum MediaImport {
    /// 按目标尺寸下采样解码为 UIImage（仅 MainActor 路径：相机拍摄即时预览）。
    static func downsample(_ data: Data, maxPixel: CGFloat = 480) -> UIImage? {
        guard let cg = downsampledCGImage(data, maxPixel: maxPixel) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 按目标尺寸下采样并编码为 JPEG Data（非隔离上下文可用，Sendable 产出）。
    static func thumbnailData(_ data: Data, maxPixel: CGFloat = 480) -> Data? {
        guard let cg = downsampledCGImage(data, maxPixel: maxPixel),
              let out = NSMutableData() as CFMutableData?,
              let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// 并发加载所选照片并产出下采样缩略图（保持选择顺序；单张失败跳过）。
    /// 非隔离 async（静态函数）：调用方从 MainActor Task 调用时在通用执行器上执行，
    /// 只跨边界传递 Sendable 值。
    static func loadWithThumbnails(_ items: [PhotosPickerItem]) async -> (data: [Data], thumbs: [Data]) {
        let results = await withTaskGroup(of: (Int, Data?, Data?).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    let data = try? await item.loadTransferable(type: Data.self) // try?-ok: 单张照片传输失败跳过该张，其余照常（§7 显式降级）
                    return (index, data, data.flatMap { thumbnailData($0) })
                }
            }
            var out: [(Int, Data)] = []
            var thumbs: [(Int, Data)] = []
            for await (index, data, thumb) in group {
                if let data { out.append((index, data)) }
                if let thumb { thumbs.append((index, thumb)) }
            }
            return (out.sorted { $0.0 < $1.0 }, thumbs.sorted { $0.0 < $1.0 })
        }
        return (results.0.map(\.1), results.1.map(\.1))
    }

    /// ImageIO 下采样核心（EXIF 方向自动矫正）；失败返回 nil。
    private static func downsampledCGImage(_ data: Data, maxPixel: CGFloat) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
