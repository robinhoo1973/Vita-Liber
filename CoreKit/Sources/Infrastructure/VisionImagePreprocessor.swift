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

        // 1) 解码为 CGImage
        guard let cgImage = decodeCGImage(originalData) else { throw PreprocessError.decodeFailed }

        // 2) 透视矫正（若启用）
        var corrected: CIImage = CIImage(cgImage: cgImage)
        if params.enablePerspectiveCorrection {
            corrected = try await detectAndCorrectPerspective(corrected)
        }

        // 3) 色彩模式
        corrected = applyColorMode(corrected, mode: params.colorMode)

        // 4) 旋转（评审修正：CGImagePropertyOrientation 无 rotationDegrees 工厂——
        //    方向枚举八态语义含 EXIF 隐含翻转，不适合表达「旋转 N 度」；
        //    用 CGAffineTransform 旋转，正角 = 逆时针（CG 坐标），与预览旋转一致）
        if params.rotationDegrees != 0 {
            let angle = Double(params.rotationDegrees) * .pi / 180.0
            corrected = corrected.transformed(by: CGAffineTransform(rotationAngle: angle))
        }

        // 5) 编码为 JPEG Data
        let processedData = try encodeToJPEG(corrected)

        return PreprocessedImage(processedData: processedData,
                                 originalData: originalData,
                                 appliedParams: params,
                                 version: baseVersion + 1)
    }

    // MARK: - 私有实现

    private func decodeCGImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return cg
    }

    private func detectAndCorrectPerspective(_ ciImage: CIImage) async throws -> CIImage {
        // Vision 边缘检测（在后台队列，避免阻塞主线程 —— C7）
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 3.0
        request.minimumSize = 0.2
        request.maximumObservations = 1

        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        try handler.perform([request])

        guard let obs = request.results?.first as? VNRectangleObservation,
              obs.confidence > 0.6 else {
            throw PreprocessError.noDocumentDetected
        }

        // 顶点归一化坐标 → CIFilter.perspectiveCorrection 输入
        let topLeft = obs.topLeft
        let topRight = obs.topRight
        let bottomLeft = obs.bottomLeft
        let bottomRight = obs.bottomRight

        let extent = ciImage.extent
        let inputTopLeft = CIVector(x: topLeft.x * extent.width, y: (1 - topLeft.y) * extent.height)
        let inputTopRight = CIVector(x: topRight.x * extent.width, y: (1 - topRight.y) * extent.height)
        let inputBottomLeft = CIVector(x: bottomLeft.x * extent.width, y: (1 - bottomLeft.y) * extent.height)
        let inputBottomRight = CIVector(x: bottomRight.x * extent.width, y: (1 - bottomRight.y) * extent.height)

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            throw PreprocessError.perspectiveCorrectionFailed
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(inputTopLeft, forKey: "inputTopLeft")
        filter.setValue(inputTopRight, forKey: "inputTopRight")
        filter.setValue(inputBottomLeft, forKey: "inputBottomLeft")
        filter.setValue(inputBottomRight, forKey: "inputBottomRight")

        guard let output = filter.outputImage else { throw PreprocessError.perspectiveCorrectionFailed }
        return output
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
        let context = CIContext()
        guard let cg = context.createCGImage(image, from: image.extent),
              let data = NSMutableData() as CFMutableData?,
              let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PreprocessError.encodeFailed
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PreprocessError.encodeFailed }
        return data as Data
    }
}
#endif