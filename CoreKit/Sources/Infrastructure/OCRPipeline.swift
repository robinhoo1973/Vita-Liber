#if os(iOS) || os(macOS)
import Foundation
import Domain
import Protocols

/// ADR-026 编排层类型（V3.50 承诺、此前缺失）：OCR 管线统一编排点——
/// 解码（灰度）→ 质量评估（FR5.3 模糊/反光提示，不阻止保存）→ 识别 →
/// 归一化文本。上层（App 状态仓）只依赖本类型与能力协议，不直接持有
/// 具体引擎（EAL 纪律）。
///
/// 双轨语义与引擎无关：无论 Vision 轨（iOS 生产）还是 PaddleOCR 轨
/// （Linux 开发），产出都是 `lines+confidence` 归一化结果；确认流与
/// BR-003 D→C 分级不感知具体引擎。
public struct OCRPipeline: Sendable {
    private let recognizer: any ImageTextRecognizing
    private let grayscaleDecoder: any GrayscaleDecoding

    public init(recognizer: any ImageTextRecognizing, grayscaleDecoder: any GrayscaleDecoding) {
        self.recognizer = recognizer
        self.grayscaleDecoder = grayscaleDecoder
    }

    public struct Result: Sendable, Equatable {
        public var lines: [String]
        public var hasText: Bool
        /// FR5.3 质量提示标签（模糊/过暗/疑似遮挡——提示重拍但不阻止保存）
        public var qualityTags: [String]
        public init(lines: [String], hasText: Bool, qualityTags: [String] = []) {
            self.lines = lines; self.hasText = hasText; self.qualityTags = qualityTags
        }
    }

    /// 单图管线：灰度解码 → 质量评估（FR5.3）→ 识别。
    /// 识别失败 = 空结果 + 质量标签（FR6.6 边界：纯影像页无文字不视为错误流程）。
    public func run(imageData: Data) async throws -> Result {
        var tags: [String] = []
        do {
            let grayscale = try grayscaleDecoder.decode(imageData, maxDimension: 256)
            tags = CaptureQualityAssessor.assess(grayscale).tags
        } catch {
            tags = []   // 质量评估失败不阻断识别主链路
        }
        do {
            let recognition = try await recognizer.recognize(imageData)
            return Result(lines: recognition.lines, hasText: !recognition.lines.isEmpty,
                          qualityTags: tags)
        } catch {
            return Result(lines: [], hasText: false, qualityTags: tags)
        }
    }
}
#endif
