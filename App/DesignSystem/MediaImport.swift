import SwiftUI
import UIKit
import PhotosUI
import ImageIO

/// 媒体导入共用件：ImageIO 下采样（§5.10 纪律——原图不整图解码进内存）
/// 与 PhotosPicker 并发加载。观察创建（F8）与资料库拍摄（F5）复用。
enum MediaImport {
    /// 按目标尺寸下采样解码（EXIF 方向自动矫正）；失败返回 nil。
    static func downsample(_ data: Data, maxPixel: CGFloat = 480) -> UIImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 并发加载所选照片（保持选择顺序），单张失败跳过。
    static func load(_ items: [PhotosPickerItem]) async -> [Data] {
        let results = await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask { (index, try? await item.loadTransferable(type: Data.self)) } // try?-ok: 单张照片传输失败跳过该张，其余照常（§7 显式降级）
            }
            var out: [(Int, Data)] = []
            for await (index, data) in group {
                if let data { out.append((index, data)) }
            }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return results
    }
}
