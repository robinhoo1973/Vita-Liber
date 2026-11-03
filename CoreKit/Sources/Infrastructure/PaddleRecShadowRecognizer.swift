#if os(iOS) || os(macOS)
// linux-blind: Vision/CoreGraphics/ORT 仅在 Apple 切片；Linux 走 Vision 桩。
import Foundation
import Domain
import Protocols

/// PP-OCRv6 rec-only 影子引擎（2026-11-03 真机调参批）。
///
/// 生产输出仍是 Vision：本类型只把 Vision 每行裁剪后跑 Paddle rec，生成
/// `OCRDebugTrace` 供会话目录诊断。模型缺失/加载失败/单行失败都不影响
/// Vision 结果，绝不抛错替代识别失败。用户未开启诊断时不落盘。
public actor PaddleRecShadowRecognizer: ImageTextRecognizing {
    private let primary: any ImageTextRecognizing
    private var session: ONNXRuntimeSession?
    private var loaded: OCRModelStore.Loaded?
    private var sessionUnavailable = false

    public init(primary: any ImageTextRecognizing = VisionImageRecognizer()) {
        self.primary = primary
    }

    public func recognize(_ imageData: Data) async throws -> ImageInputRules.Recognition {
        let base = try await primary.recognize(imageData)
        try Task.checkCancellation()
        // 诊断默认关闭：不加载模型、不跑 ONNX、不产生 trace。
        guard OCRShadowDiagnostics.isEnabled else { return base }
        guard !base.lines.isEmpty, let layout = base.layout, !layout.blocks.isEmpty else { return base }
        guard let model = await OCRModelStore.shared.load() else {
            return Self.annotated(base, engine: "paddle-unavailable", reason: "model-missing")
        }
        if session == nil, !sessionUnavailable {
            do {
                session = try ONNXRuntimeSession(modelData: model.modelData)
                loaded = model
            } catch {
                sessionUnavailable = true
            }
        }
        guard let session, let loaded else {
            return Self.annotated(base, engine: "paddle-unavailable", reason: "session-failed")
        }
        guard let page = PaddleRecPreprocessor.page(from: imageData) else {
            return Self.annotated(base, engine: "paddle-unavailable", reason: "image-decode-failed")
        }

        let started = Date()
        var lines: [OCRDebugTrace.Line] = []
        for block in layout.blocks.sorted(by: { ($0.lineIndex, $0.bbox.midY) < ($1.lineIndex, $1.bbox.midY) }) {
            try Task.checkCancellation()
            let lineIndex = block.lineIndex
            guard lineIndex >= 0, lineIndex < base.lines.count else { continue }
            guard let prepared = PaddleRecPreprocessor.prepare(
                page: page, bbox: block.bbox,
                height: loaded.asset.height, maxWidth: loaded.asset.maxWidth) else {
                lines.append(.init(lineIndex: lineIndex, bbox: Self.bboxArray(block.bbox),
                                   visionText: base.lines[lineIndex], paddleText: "",
                                   visionConfidence: Double(block.confidence),
                                   paddleConfidence: 0,
                                   cropWidth: 0, cropHeight: 0, recWidth: 0,
                                   timesteps: 0, latencyMs: 0, error: "crop-failed"))
                continue
            }
            let lineStarted = Date()
            do {
                let output = try session.run(input: prepared.tensor,
                                             height: loaded.asset.height,
                                             width: prepared.width)
                let decoded = CTCDecoder.decode(
                    probabilities: output.probabilities, timesteps: output.timesteps,
                    classes: output.classes, vocabulary: loaded.vocabulary,
                    blankIndex: loaded.asset.blankIndex)
                lines.append(.init(
                    lineIndex: lineIndex, bbox: Self.bboxArray(block.bbox),
                    visionText: base.lines[lineIndex], paddleText: decoded.text,
                    visionConfidence: Double(block.confidence),
                    paddleConfidence: decoded.confidence,
                    cropWidth: prepared.cropWidth, cropHeight: prepared.cropHeight,
                    recWidth: prepared.width, timesteps: output.timesteps,
                    latencyMs: Date().timeIntervalSince(lineStarted) * 1000))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lines.append(.init(
                    lineIndex: lineIndex, bbox: Self.bboxArray(block.bbox),
                    visionText: base.lines[lineIndex], paddleText: "",
                    visionConfidence: Double(block.confidence), paddleConfidence: 0,
                    cropWidth: prepared.cropWidth, cropHeight: prepared.cropHeight,
                    recWidth: prepared.width, timesteps: 0,
                    latencyMs: Date().timeIntervalSince(lineStarted) * 1000,
                    error: String(describing: error)))
            }
        }
        let trace = OCRDebugTrace(
            model: loaded.displayName, modelSHA256: loaded.modelSHA256,
            engine: "PP-OCRv6_small_rec/onnxruntime",
            totalLatencyMs: Date().timeIntervalSince(started) * 1000,
            lines: lines)
        return ImageInputRules.Recognition(lines: base.lines, confidence: base.confidence,
                                           layout: base.layout, debugTrace: trace)
    }

    private static func bboxArray(_ rect: LayoutRect) -> [Double] {
        [rect.x, rect.y, rect.width, rect.height]
    }

    /// 模型/会话/解码不可用时也留一条诊断，业主能区分「Paddle 没跑」与「跑了但没差异」。
    private static func annotated(_ base: ImageInputRules.Recognition,
                                  engine: String, reason: String) -> ImageInputRules.Recognition {
        let trace = OCRDebugTrace(model: "PP-OCRv6_small_rec", modelSHA256: "",
                                  engine: engine, totalLatencyMs: 0,
                                  lines: [.init(lineIndex: -1, bbox: [], visionText: "",
                                                paddleText: "", visionConfidence: 0,
                                                paddleConfidence: 0, cropWidth: 0,
                                                cropHeight: 0, recWidth: 0, timesteps: 0,
                                                latencyMs: 0, error: reason)])
        return ImageInputRules.Recognition(lines: base.lines, confidence: base.confidence,
                                           layout: base.layout, debugTrace: trace)
    }
}
#endif
