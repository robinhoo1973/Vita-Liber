import Foundation

/// §5.1 / §2.2 / M-PREPROC：扫描预处理 / 图片变形校正 Domain 类型。
///
/// 原始帧并存（BR-002）：每版处理结果与原始帧并存；不可逆像素涂写仅作用于处理后版本，
/// 原始帧不受影响但受敏感保护链管辖。

/// 预处理参数（确定性：相同输入+参数 → 相同输出）。
public struct PreprocessParams: Sendable, Equatable, Codable {
    /// 是否启用自动边缘检测与透视矫正。
    public var enablePerspectiveCorrection: Bool
    /// 色彩模式。
    public var colorMode: ColorMode
    /// 旋转角度（0/90/180/270 度）。
    public var rotationDegrees: Int
    /// 是否为重置操作（忽略其他参数，回退原始帧）。
    public var resetToOriginal: Bool

    public init(enablePerspectiveCorrection: Bool = true,
                colorMode: ColorMode = .color,
                rotationDegrees: Int = 0,
                resetToOriginal: Bool = false) {
        self.enablePerspectiveCorrection = enablePerspectiveCorrection
        self.colorMode = colorMode
        self.rotationDegrees = rotationDegrees
        self.resetToOriginal = resetToOriginal
    }

    public enum ColorMode: String, Sendable, Codable, CaseIterable {
        case color = "color"
        case grayscale = "grayscale"
        case binary = "binary"
    }
}

/// 预处理结果：处理后图像 Data + 原始帧引用（不拷贝原始 Data，避免内存翻倍）。
public struct PreprocessedImage: Sendable {
    /// 处理后图像 Data（JPEG/PNG）。
    public var processedData: Data
    /// 原始帧 Data（引用，不拷贝）。
    public var originalData: Data
    /// 应用的参数（用于审计/重放）。
    public var appliedParams: PreprocessParams
    /// 处理版本号（每次处理递增，配合 BR-002 原始帧并存）。
    public var version: Int

    public init(processedData: Data, originalData: Data, appliedParams: PreprocessParams, version: Int) {
        self.processedData = processedData
        self.originalData = originalData
        self.appliedParams = appliedParams
        self.version = version
    }
}

/// 预处理错误。
public enum PreprocessError: Error, Sendable, Equatable {
    case noDocumentDetected       // 未检测到文档四边
    case perspectiveCorrectionFailed
    case invalidRotation
    case decodeFailed
    case encodeFailed
}

/// 预处理协议（跨平台统一接口）。
public protocol ImagePreprocessing: Sendable {
    /// 对原始图像进行预处理（边缘检测+透视矫正+色彩模式+旋转）。
    /// - 原始帧 `originalData` 不被修改（BR-002）。
    /// - 返回 `PreprocessedImage`，含处理后 Data + 原始帧引用 + 版本号。
    func preprocess(_ originalData: Data, params: PreprocessParams, baseVersion: Int) async throws -> PreprocessedImage
}