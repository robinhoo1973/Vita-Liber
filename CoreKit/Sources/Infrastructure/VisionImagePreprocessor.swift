#if os(iOS) || os(macOS)
import Foundation
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Domain
import Protocols

/// M-PREPROC Apple 生产轨：Vision 边缘检测 + Core Image 透视矫正。
///
/// - `VNDetectRectanglesRequest` 检测文档四边（§5.1 C1）。
/// - `CIFilter.perspectiveCorrection` 将倾斜拍摄校正为正射视图（§2.2 C2）。
/// - 色彩模式/旋转/重置由 Core Image 完成（FR5.2 C3/C4）。
/// - 原始帧并存：每次处理返回新 `PreprocessedImage`，原始 Data 不修改（BR-002 C5）。
public final class VisionImagePreprocessor: ImagePreprocessing, @unchecked Sendable {
    public init() {}

    public func preprocess(_ originalData: Data, params: PreprocessParams, baseVersion: Int) async throws -> PreprocessedImage {
        guard !params.resetToOriginal else {
            // 重置：直接返回原始帧作为处理结果（版本号+1），不做任何像素修改。
            return PreprocessedImage(processedData: originalData,
                                     originalData: originalData,
                                     appliedParams: params,
                                     version: baseVersion + 1)
        }

        // 从 MainActor 视图 await 进来时函数体无 actor 跳转（Vision 检测/
        // 矫正/JPEG 编码全程 CPU 密集），detached 跳出主线程执行（H3 效率修复）。
        return try await Task.detached(priority: .userInitiated) {
            // 1) 解码为 CGImage（EXIF 方向已归一化——decodeCGImage 见下）
            guard let cgImage = self.decodeCGImage(originalData) else { throw PreprocessError.decodeFailed }

            // 2) 透视矫正（若启用）
            var corrected: CIImage = CIImage(cgImage: cgImage)
            if params.enablePerspectiveCorrection {
                corrected = try await self.detectAndCorrectPerspective(corrected)
            }

            // 3) 色彩模式
            corrected = self.applyColorMode(corrected, mode: params.colorMode)

            // 4) 旋转（评审修正：CGImagePropertyOrientation 无 rotationDegrees 工厂——
            //    方向枚举八态语义含 EXIF 隐含翻转，不适合表达「旋转 N 度」；
            //    用 CGAffineTransform 旋转，正角 = 逆时针（CG 坐标），与预览旋转一致）
            if params.rotationDegrees != 0 {
                let angle = Double(params.rotationDegrees) * .pi / 180.0
                corrected = corrected.transformed(by: CGAffineTransform(rotationAngle: angle))
            }

            // 5) 编码为 JPEG Data
            let processedData = try self.encodeToJPEG(corrected)

            return PreprocessedImage(processedData: processedData,
                                     originalData: originalData,
                                     appliedParams: params,
                                     version: baseVersion + 1)
        }.value
    }

    // MARK: - 私有实现

    /// 解码并归一化 EXIF 方向（第四轮全仓审查修复，5WHY 根因）：
    /// 竖拍照片（EXIF orientation 6/8）的原始传感器像素是横版，而 UI 显示
    /// （UIImage）按方向元数据旋转为竖版——此前 decodeCGImage 用
    /// CGImageSourceCreateImageAtIndex 不应用方向变换，检测/矫正作用于横版
    /// 像素空间、四角手柄作用于竖版显示空间，两者相差 90°→矫正输出旋转/畸变。
    /// 改走 Thumbnail API（kCGImageSourceCreateThumbnailWithTransform 应用
    /// EXIF 变换），MaxPixelSize 取原图最长边——不降采样只归正。
    private func decodeCGImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let maxPixels = max(width, height, 1)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    private func detectAndCorrectPerspective(_ ciImage: CIImage) async throws -> CIImage {
        guard let obs = try await detectQuad(ciImage) else { throw PreprocessError.noDocumentDetected }
        return try perspectiveCorrect(ciImage, quad: quadCorners(from: obs))
    }

    /// Vision 矩形检测（后台队列，不阻塞主线程 —— C7）：返回归一化四角
    /// （左下原点，Vision 原生坐标系）；置信度不足/未检出返回 nil。
    private func detectQuad(_ ciImage: CIImage) async throws -> VNRectangleObservation? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 3.0
        request.minimumSize = 0.2
        request.maximumObservations = 1

        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        try handler.perform([request])

        guard let obs = request.results?.first as? VNRectangleObservation,
              obs.confidence > 0.6 else { return nil }
        return obs
    }

    /// Vision 左下原点 → QuadCorners 左上原点（UIKit 惯例）：y 取反。
    /// 全仓唯一换算出口（第四轮全仓审查修复：原「1 - y」翻转曾以三种形态
    /// 散落三处——obs 重载内联×4、quad 重载 toVector、detectQuad flip，
    /// 坐标系语义修正须同步三处，漏改一处即自动/手动矫正镜像错位）。
    private func quadCorners(from obs: VNRectangleObservation) -> QuadCorners {
        func flip(_ p: CGPoint) -> Domain.NormalizedPoint {
            Domain.NormalizedPoint(x: Double(p.x), y: 1 - Double(p.y))
        }
        return QuadCorners(topLeft: flip(obs.topLeft), topRight: flip(obs.topRight),
                           bottomLeft: flip(obs.bottomLeft), bottomRight: flip(obs.bottomRight))
    }

    /// 按四角（`QuadCorners`：左上原点归一化坐标，交互式选区 UI 的坐标契约）
    /// 对图像做透视矫正——Y 轴翻转把 UIKit 惯例换算成 Core Image 的左下原点像素坐标。
    private func perspectiveCorrect(_ ciImage: CIImage, quad: QuadCorners) throws -> CIImage {
        let extent = ciImage.extent
        func toVector(_ p: Domain.NormalizedPoint) -> CIVector {
            CIVector(x: CGFloat(p.x) * extent.width, y: (1 - CGFloat(p.y)) * extent.height)
        }
        return try applyPerspectiveFilter(ciImage, topLeft: toVector(quad.topLeft), topRight: toVector(quad.topRight),
                                          bottomLeft: toVector(quad.bottomLeft), bottomRight: toVector(quad.bottomRight))
    }

    private func applyPerspectiveFilter(_ ciImage: CIImage, topLeft: CIVector, topRight: CIVector,
                                        bottomLeft: CIVector, bottomRight: CIVector) throws -> CIImage {
        // 退化四边形（三点近似共线/选区过小）防护：CIPerspectiveCorrection 对这种
        // 输入不会抛错，而是产出畸变或近乎空白的输出——提前用面积法判定并拒绝。
        guard quadArea(topLeft: topLeft, topRight: topRight, bottomLeft: bottomLeft, bottomRight: bottomRight)
                > ciImage.extent.width * ciImage.extent.height * 0.01 else {
            throw PreprocessError.perspectiveCorrectionFailed
        }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            throw PreprocessError.perspectiveCorrectionFailed
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(topLeft, forKey: "inputTopLeft")
        filter.setValue(topRight, forKey: "inputTopRight")
        filter.setValue(bottomLeft, forKey: "inputBottomLeft")
        filter.setValue(bottomRight, forKey: "inputBottomRight")
        guard let output = filter.outputImage else { throw PreprocessError.perspectiveCorrectionFailed }
        return output
    }

    /// 鞋带公式（Shoelace formula）算四边形面积——面积过小视为退化选区。
    private func quadArea(topLeft: CIVector, topRight: CIVector, bottomLeft: CIVector, bottomRight: CIVector) -> CGFloat {
        let pts = [topLeft, topRight, bottomRight, bottomLeft]
        var sum: CGFloat = 0
        for i in 0..<pts.count {
            let a = pts[i]; let b = pts[(i + 1) % pts.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    private func applyColorMode(_ image: CIImage, mode: PreprocessParams.ColorMode) -> CIImage {
        switch mode {
        case .color: return image
        case .grayscale:
            guard let filter = CIFilter(name: "CIColorControls") else { return image }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(0.0, forKey: kCIInputSaturationKey)
            return filter.outputImage ?? image
        case .binary:
            guard let filter = CIFilter(name: "CIColorControls") else { return image }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(0.0, forKey: kCIInputSaturationKey)
            filter.setValue(2.0, forKey: kCIInputContrastKey)
            return filter.outputImage ?? image
        }
    }

    private func encodeToJPEG(_ image: CIImage) throws -> Data {
        // 共享 CIContext（GPU 上下文创建成本高；CIContext 线程安全可跨调用复用——
        // 第四轮全仓审查效率修复，与 CoreImageCompressor 同纪律）
        let context = Self.sharedContext
        guard let cg = context.createCGImage(image, from: image.extent),
              let data = NSMutableData() as CFMutableData?,
              let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PreprocessError.encodeFailed
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PreprocessError.encodeFailed }
        return data as Data
    }

    private static let sharedContext = CIContext()

    // MARK: - 交互式选区（M-PREPROC 手动裁剪，用户拖拽四角）

    public func detectQuad(_ originalData: Data) async -> QuadCorners? {
        // 从 MainActor 视图（ScanRegionEditorView）await 进来：detached 跳出主线程，
        // 解码+Vision 检测不冻结 UI（H3 效率修复）
        await Task.detached(priority: .userInitiated) {
            guard let cgImage = self.decodeCGImage(originalData) else { return nil }
            let ciImage = CIImage(cgImage: cgImage)
            guard let obs = try? await self.detectQuad(ciImage) else { return nil }   // try?-ok: 检测失败按「未检出」处理，UI 回落整图四角，不是错误流程
            return self.quadCorners(from: obs)
        }.value
    }

    public func correctPerspective(_ originalData: Data, corners: QuadCorners) async throws -> Data {
        // detached：透视矫正 + JPEG 编码为 CPU/GPU 密集，不阻塞主线程（H3 效率修复）
        try await Task.detached(priority: .userInitiated) {
            guard let cgImage = self.decodeCGImage(originalData) else { throw PreprocessError.decodeFailed }
            let ciImage = CIImage(cgImage: cgImage)
            let corrected = try self.perspectiveCorrect(ciImage, quad: corners)
            return try self.encodeToJPEG(corrected)
        }.value
    }
}
#endif