#if os(Linux)
import Foundation
import Domain
import Protocols

/// ADR-026 Linux/dev 轨道：PaddleOCR-on-ONNX（ONNX Runtime + PP-OCRv5/v6 三件套 + 字典）。
///
/// 真实推理依赖 `onnxruntime-swift-package-manager`（Package.swift 以 `#if os(Linux)` 条件引入，
/// 绝不进入 iOS 生产 target）。本机未引入依赖时 `canImport(OCRRuntime)` 为假，退化为占位实现，
/// 保证 Linux 构建/测试可跑、不阻塞 EAL 与上层确认流程；依赖就位后自动切换真实推理，无需改调用方。
public struct PaddleOCRImageRecognizer: ImageTextRecognizing {
    public init() {}

    public func recognize(_ imageData: Data) async throws -> ImageInputRules.Recognition {
        #if canImport(COnnxRuntime)
        let runtime = await NativePPOCRRuntime.shared   // 见 tech-spec §5.2.3 的 actor 封装
        let result = try await runtime.recognize(imageData)
        guard !result.lines.isEmpty else { return .init(lines: [], confidence: 0) }
        let confidence = result.confidences.reduce(0, +) / Double(result.confidences.count)
        return .init(lines: result.lines, confidence: confidence)
        #else
        // 占位：PaddleOCR 依赖未引入时的退化实现；真实推理见 tech-spec §5.2.2 / §5.2.3
        ImageInputRules.Recognition(lines: [], confidence: 0)
        #endif
    }
}
#endif
