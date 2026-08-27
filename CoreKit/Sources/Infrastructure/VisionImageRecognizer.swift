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
        guard let handler = VNImageRequestHandler(data: imageData) else {
            throw RecognizeError.invalidImage
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // 报告类文档常为多语言混排（中英数字），自动检测优于指定单一语言
        request.recognitionLanguages = ["zh-Hans", "en-US"]
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
        case invalidImage
        case engineFailed
        public var errorDescription: String? { "图片识别失败: \(self)" }
    }
}
#endif
