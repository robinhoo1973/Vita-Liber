#if os(iOS) || os(macOS)
// linux-blind: CoreGraphics/ImageIO 缩放与 ORT 会话仅在 Apple 切片。
import Foundation
import CoreGraphics
import Domain
import Protocols

/// PP-OCRv6 det 预处理（2026-11-04 Paddle 主轨批）。
///
/// 与官方 `inference.yml` 同源：
/// - `DetResizeForTest`：短边放大到 `maxSide`，长边上限 4000，尺寸取 32 的整数倍；
/// - `NormalizeImage`：`(v/255 - mean) / std`，按 catalog 的通道序（BGR）；
/// - `ToCHWImage`：HWC → CHW。
///
/// **坐标系与 rec 一致**：复用 `PaddleRecPreprocessor.page(from:)` 的原样解码
/// （不应用 EXIF 旋转），检测框归一化后可直接用于同一页的裁片。
public enum PaddleDetPreprocessor {
    public struct Prepared: Sendable {
        public var tensor: [Float]
        public var width: Int
        public var height: Int
    }

    /// 长边硬上限（与官方 `DetResizeForTest` 的 4000 一致）。
    public static let maxLongSide = 4000

    public static func prepare(page: PaddleRecPreprocessor.Page,
                               asset: OCRModelStore.DetectorAsset) -> Prepared? {
        guard asset.maxSide > 0, asset.mean.count == 3, asset.std.count == 3,
              asset.std.allSatisfy({ $0 != 0 }) else { return nil }
        let image = page.image
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        var ratio = 1.0
        let minSide = Double(min(width, height))
        let maxSide = Double(max(width, height))
        if minSide < Double(asset.maxSide) {
            ratio = Double(asset.maxSide) / minSide
        }
        // 短边放大后再压低长边：两个方向共用同一 ratio，绝不分别截断，
        // 否则超长图会被压扁（检测框与裁片坐标随之一致失真）。
        if maxSide * ratio > Double(maxLongSide) {
            ratio = Double(maxLongSide) / maxSide
        }
        let targetWidth = max(32, Int((Double(width) * ratio / 32).rounded()) * 32)
        let targetHeight = max(32, Int((Double(height) * ratio / 32).rounded()) * 32)
        guard targetWidth > 0, targetHeight > 0,
              targetWidth <= maxLongSide, targetHeight <= maxLongSide else { return nil }

        var pixels = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var drew = false
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: targetWidth, height: targetHeight,
                                          bitsPerComponent: 8, bytesPerRow: targetWidth * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
            context.interpolationQuality = .high
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            drew = true
        }
        guard drew else { return nil }

        let plane = targetWidth * targetHeight
        var tensor = [Float](repeating: 0, count: plane * 3)
        let bgr = asset.channelOrder.uppercased() != "RGB"
        for index in 0..<plane {
            let offset = index * 4
            let r = Float(pixels[offset]) / 255
            let g = Float(pixels[offset + 1]) / 255
            let b = Float(pixels[offset + 2]) / 255
            let channels: (Float, Float, Float) = bgr ? (b, g, r) : (r, g, b)
            tensor[index] = (channels.0 - Float(asset.mean[0])) / Float(asset.std[0])
            tensor[plane + index] = (channels.1 - Float(asset.mean[1])) / Float(asset.std[1])
            tensor[plane * 2 + index] = (channels.2 - Float(asset.mean[2])) / Float(asset.std[2])
        }
        return Prepared(tensor: tensor, width: targetWidth, height: targetHeight)
    }
}

/// det 会话（Paddle 主轨）。与影子机同一套 `ONNXRuntimeSession`，
/// 只是把输出解释为 H×W 概率图并交给 Domain `DBTextPostprocess`。
///
/// 单会话、由 `PaddlePrimaryRecognizer` actor 串行调用；失败即锁定不可用，
/// 不重试、不联网、不落盘。
public actor PaddleTextDetector {
    public struct Detection: Sendable {
        public var boxes: [DBTextPostprocess.Box]
        public var latencyMs: Double
        public var model: String
        public var modelSHA256: String
        /// 预处理后的概率图尺寸（诊断用）。
        public var mapWidth: Int
        public var mapHeight: Int
    }

    private var session: ONNXRuntimeSession?
    private var loaded: OCRModelStore.Detector?
    private var unavailable = false

    public init() {}

    /// nil = 模型缺失/会话失败/推理失败/解码失败——调用方按副轨 Vision 交付。
    ///
    /// 入参是 `Data`（Sendable）：页解码放在本 actor 内完成，避免
    /// `CGImage` 跨隔离域传递；rec 侧会再解码一次（每页一次，成本可接受）。
    public func detect(imageData: Data) async -> Detection? {
        guard !unavailable else { return nil }
        guard let page = PaddleRecPreprocessor.page(from: imageData) else { return nil }
        guard let model = await OCRModelStore.shared.loadDetector() else { return nil }
        if session == nil {
            do {
                session = try ONNXRuntimeSession(modelData: model.modelData,
                                                 inputName: model.asset.inputName,
                                                 outputName: model.asset.outputName)
                loaded = model
            } catch {
                unavailable = true
                return nil
            }
        }
        guard let session, let loaded else { return nil }
        guard let prepared = PaddleDetPreprocessor.prepare(page: page, asset: loaded.asset) else {
            return nil
        }
        let started = Date()
        do {
            let output = try session.run(input: prepared.tensor,
                                         height: prepared.height, width: prepared.width)
            var options = DBTextPostprocess.Options.ppocrv6SmallDet
            options.thresh = loaded.asset.thresh
            options.boxThresh = loaded.asset.boxThresh
            options.unclipRatio = loaded.asset.unclipRatio
            options.maxCandidates = loaded.asset.maxCandidates
            let boxes = DBTextPostprocess.boxes(probabilities: output.probabilities,
                                                height: output.timesteps,
                                                width: output.classes,
                                                options: options)
            return Detection(boxes: DBTextPostprocess.ordered(boxes),
                             latencyMs: Date().timeIntervalSince(started) * 1000,
                             model: loaded.displayName,
                             modelSHA256: loaded.modelSHA256,
                             mapWidth: output.classes, mapHeight: output.timesteps)
        } catch {
            return nil
        }
    }
}
#endif
