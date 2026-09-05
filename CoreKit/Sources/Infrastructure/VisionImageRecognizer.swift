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
        // VNImageRequestHandler(data:) 在 iOS 18 SDK 是非 failable 初始化器，
        // `guard let` 的 optional 绑定直接编译失败（CI Xcode 16 报
        // 「initializer for conditional binding must have Optional type」；
        // 本地 Linux 不编译此文件故未暴露——ERR#29 结构性盲区）。
        let handler = VNImageRequestHandler(data: imageData)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // 报告类文档常为多语言混排（中英数字），自动检测优于指定单一语言。
        // 审查修复：原硬编码 ["zh-Hans","en-US"] 恰好关掉了自动检测——
        // zh-Hant 与其它语言文档被强制走简体模型（药/藥 类字形误识）。
        // 置 nil = Vision 自动语言检测（zh-Hant 用户扫描繁体报告走对模型）。
        request.recognitionLanguages = nil
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
