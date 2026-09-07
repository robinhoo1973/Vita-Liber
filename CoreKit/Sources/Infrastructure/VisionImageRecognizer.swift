// 平台守卫镜像 Package.swift（ERR#8 纪律）：Vision 仅 Apple 平台可用。
#if os(iOS) || os(macOS)
import Foundation
import Vision
import Domain
import Protocols

/// FR12.11 的生产实现：Vision `VNRecognizeTextRequest`。
///
/// - **端上识别**（离线零网络——隐私红线延伸）；
/// - 零落盘：入参是 `Data`、出参是文本行，中间不产生任何文件；
/// - **只负责识别**：D 级待确认判定在 Domain `ImageInputRules`，
///   本类绝不越权把识别结果标成确认。
public final class VisionImageRecognizer: ImageTextRecognizing, @unchecked Sendable {
    public init() {}

    public func recognize(_ imageData: Data) async throws -> ImageInputRules.Recognition {
        // 第四轮全仓审查效率修复（5WHY）：函数体无 actor 跳转，从 MainActor
        // （OCRPipeline ← DocumentsState 导入流）await 进来时全分辨率
        // .accurate 识别在主线程同步执行，逐页 PDF 连续卡 UI。detached 跳出
        // 主线程；VN handler/request 非 Sendable，全部在闭包内构造不外逃。
        try await Task.detached(priority: .userInitiated) {
            try Self.performRecognition(imageData)
        }.value
    }

    private static func performRecognition(_ imageData: Data) throws -> ImageInputRules.Recognition {
        // VNImageRequestHandler(data:) 在 iOS 18 SDK 是非 failable 初始化器，
        // `guard let` 的 optional 绑定直接编译失败（CI Xcode 16 报
        // 「initializer for conditional binding must have Optional type」；
        // 本地 Linux 不编译此文件故未暴露——ERR#29 结构性盲区）。
        let handler = VNImageRequestHandler(data: imageData)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // FR5.x（OCR 语言契约）：默认识别简体/繁体/英文三语——显式列出
        // ["zh-Hans","zh-Hant","en-US"]，Vision 按候选语言逐块选最优模型。
        // 不得置空依赖自动检测：空数组在准确级下会退回设备主语言优先的
        // 弱检测，繁体/英文混排文档易被简体模型误识（药/藥 类字形错别）。
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        do {
            try handler.perform([request])
        } catch {
            throw RecognizeError.engineFailed
        }
        guard let observations = request.results else {
            return ImageInputRules.Recognition(lines: [], confidence: 0)
        }
        var lines: [String] = []
        var confidenceSum = 0.0
        for obs in observations {
            if let candidate = obs.topCandidates(1).first {
                lines.append(candidate.string)
                confidenceSum += Double(candidate.confidence)
            }
        }
        let confidence = lines.isEmpty ? 0 : confidenceSum / Double(lines.count)
        return ImageInputRules.Recognition(lines: lines, confidence: confidence)
    }

    public enum RecognizeError: Error, LocalizedError {
        case engineFailed
        public var errorDescription: String? { "图片识别失败: \(self)" }
    }
}
#endif
