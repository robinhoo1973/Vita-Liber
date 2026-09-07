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
/// 第八轮全仓审查修复：invalidRotation 全仓零构造、零 catch 分支（不可达
/// case 拉低覆盖率并掩盖真实错误处理缺位）——已删除；计划内路径随实现
/// 方一并引入。
public enum PreprocessError: Error, Sendable, Equatable {
    case noDocumentDetected       // 未检测到文档四边
    case perspectiveCorrectionFailed
    case decodeFailed
    case encodeFailed
}

/// 归一化坐标点（0...1，左上原点——UIKit/SwiftUI 惯例）。不用 CGPoint：
/// Domain 层零框架依赖（import ⊆ {Foundation}），CGPoint 属 CoreGraphics，
/// Linux 侧不一定可用；坐标系换算（Vision 左下原点）留在 Infrastructure 实现内部。
public struct NormalizedPoint: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// 手动/自动四角选区（交互式裁剪 UI 与透视矫正共用的坐标契约）。
public struct QuadCorners: Sendable, Equatable, Codable {
    public var topLeft: NormalizedPoint
    public var topRight: NormalizedPoint
    public var bottomLeft: NormalizedPoint
    public var bottomRight: NormalizedPoint

    public init(topLeft: NormalizedPoint, topRight: NormalizedPoint,
                bottomLeft: NormalizedPoint, bottomRight: NormalizedPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    /// 自动检测失败/尚未检测时的初始选区：5% 内缩的整图四角（避免选区贴边，
    /// 矫正时裁掉纸张边缘内容）。
    public static let fullImageInset = QuadCorners(
        topLeft: NormalizedPoint(x: 0.05, y: 0.05),
        topRight: NormalizedPoint(x: 0.95, y: 0.05),
        bottomLeft: NormalizedPoint(x: 0.05, y: 0.95),
        bottomRight: NormalizedPoint(x: 0.95, y: 0.95))
}

/// 预处理协议（跨平台统一接口）。
public protocol ImagePreprocessing: Sendable {
    /// 对原始图像进行预处理（边缘检测+透视矫正+色彩模式+旋转）。
    /// - 原始帧 `originalData` 不被修改（BR-002）。
    /// - 返回 `PreprocessedImage`，含处理后 Data + 原始帧引用 + 版本号。
    func preprocess(_ originalData: Data, params: PreprocessParams, baseVersion: Int) async throws -> PreprocessedImage

    /// 自动检测文档四角（供交互式选区 UI 预置拖拽手柄初始位置）。
    /// 未检测到/置信度不足时返回 nil——UI 回落 `QuadCorners.fullImageInset`。
    func detectQuad(_ originalData: Data) async -> QuadCorners?

    /// 按显式四角（用户拖拽调整后的选区）做透视矫正，跳过自动检测。
    /// 四角构成退化四边形（近似共线/面积过小）时抛 `perspectiveCorrectionFailed`。
    func correctPerspective(_ originalData: Data, corners: QuadCorners) async throws -> Data
}