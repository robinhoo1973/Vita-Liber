#if os(iOS) || os(macOS)
// linux-blind: CoreGraphics/ORT 仅在 Apple 切片；Linux 走 Vision 桩。
import Foundation
import Domain
import Protocols

/// Paddle 主轨识别器（2026-11-04 业主裁决：Paddle 主轨 + Apple Vision 副轨）。
///
/// 交付链：
/// 1. `PP-OCRv6 det` 出文本框（内置资产，`Resources/OCRModels`）；
/// 2. 逐框 `PP-OCRv6 rec` 出文本 —— **交付文字以 Paddle 为准**；
/// 3. Vision 作为副轨提供版式（段落/表格）与兜底：Paddle 没覆盖的块保留 Vision 原文；
/// 4. Paddle 缺件/会话失败/检测为空 → 整体回退 Vision（副轨即兜底，不是失败）。
///
/// 红线不变：输出仍是 D 级「识别未确认」（BR-003），不写盘、不联网；
/// 诊断轨迹只在 `OCRShadowDiagnostics` 开启时产生。
public actor PaddlePrimaryRecognizer: ImageTextRecognizing {
    public enum RecognizeError: Error, LocalizedError {
        case imageDecodeFailed
        case noEngineAvailable

        public var errorDescription: String? {
            switch self {
            case .imageDecodeFailed: return "图片解码失败"
            case .noEngineAvailable: return "识别引擎不可用"
            }
        }
    }

    private struct RecRuntime {
        var session: ONNXRuntimeSession
        var asset: OCRModelStore.Catalog.Asset
        var vocabulary: [String]
        /// 产出交付文字的 rec 模型身份（调试 JSON 的 model/modelSHA256）。
        var displayName: String
        var modelSHA256: String
    }

    private struct RecStat {
        var cropWidth: Double
        var cropHeight: Double
        var recWidth: Int
        var timesteps: Int
        var latencyMs: Double
    }

    private let secondary: any ImageTextRecognizing
    private let detector = PaddleTextDetector()
    private var rec: RecRuntime?
    private var recUnavailable = false

    public init(secondary: any ImageTextRecognizing = VisionImageRecognizer()) {
        self.secondary = secondary
    }

    public func recognize(_ imageData: Data) async throws -> ImageInputRules.Recognition {
        // 副轨先跑：Paddle 任一环节不可用时它就是交付结果。
        var vision: ImageInputRules.Recognition?
        var visionError: Error?
        do {
            vision = try await secondary.recognize(imageData)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            visionError = error
        }
        try Task.checkCancellation()

        guard let page = PaddleRecPreprocessor.page(from: imageData) else {
            if let vision { return vision }
            throw visionError ?? RecognizeError.imageDecodeFailed
        }

        let runtime = await recRuntime()
        var detection: PaddleTextDetector.Detection?
        var fallbackNote: String?
        if runtime != nil {
            detection = await detector.detect(imageData: imageData)
            if detection == nil { fallbackNote = "det-unavailable" }
        } else {
            fallbackNote = "rec-unavailable"
        }

        var lines: [PaddleLayoutMerge.Line] = []
        var stats: [String: RecStat] = [:]
        var failedLines = 0
        var recLatencyMs = 0.0
        if let detection, let runtime, !detection.boxes.isEmpty {
            for box in detection.boxes {
                try Task.checkCancellation()
                let rect = LayoutRect(x: box.x, y: box.y, width: box.width, height: box.height)
                guard let prepared = PaddleRecPreprocessor.prepare(
                    page: page, bbox: rect,
                    height: runtime.asset.height, maxWidth: runtime.asset.maxWidth) else {
                    failedLines += 1
                    continue
                }
                let started = Date()
                defer { recLatencyMs += Date().timeIntervalSince(started) * 1000 }
                do {
                    let output = try runtime.session.run(input: prepared.tensor,
                                                         height: runtime.asset.height,
                                                         width: prepared.width)
                    try CTCDecoder.validate(probabilitiesCount: output.probabilities.count,
                                            timesteps: output.timesteps,
                                            classes: output.classes,
                                            vocabularyCount: runtime.vocabulary.count,
                                            blankIndex: runtime.asset.blankIndex)
                    let decoded = CTCDecoder.decode(
                        probabilities: output.probabilities, timesteps: output.timesteps,
                        classes: output.classes, vocabulary: runtime.vocabulary,
                        blankIndex: runtime.asset.blankIndex)
                    guard !decoded.text.isEmpty else { continue }
                    lines.append(PaddleLayoutMerge.Line(text: decoded.text, bbox: rect,
                                                        confidence: decoded.confidence))
                    stats[Self.geometryKey(rect)] = RecStat(
                        cropWidth: prepared.cropWidth, cropHeight: prepared.cropHeight,
                        recWidth: prepared.width, timesteps: output.timesteps,
                        latencyMs: Date().timeIntervalSince(started) * 1000)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failedLines += 1
                }
            }
        }

        // Paddle 没出字：副轨交付（缺件/失败/空页都是可解释的降级，不是识别失败）。
        guard !lines.isEmpty else {
            if let vision {
                if OCRShadowDiagnostics.isEnabled {
                    return Self.annotated(vision, note: fallbackNote ?? "paddle-empty")
                }
                return vision
            }
            throw visionError ?? RecognizeError.noEngineAvailable
        }

        let visionConfidences = vision?.layout?.blocks.map(\.confidence) ?? []
        let merged = PaddleLayoutMerge.merge(
            paddleLines: lines,
            visionLines: vision?.lines ?? [],
            visionLayout: vision?.layout,
            visionConfidences: visionConfidences)

        var trace: OCRDebugTrace?
        if OCRShadowDiagnostics.isEnabled, let detection {
            trace = Self.trace(merged: merged, detection: detection, stats: stats,
                               recModel: runtime?.displayName, recModelSHA256: runtime?.modelSHA256,
                               recLatencyMs: recLatencyMs,
                               visionConfidences: visionConfidences,
                               failedLines: failedLines, note: fallbackNote)
        }

        return ImageInputRules.Recognition(lines: merged.lines,
                                           confidence: merged.confidence,
                                           layout: merged.layout,
                                           debugTrace: trace)
    }

    /// rec 模型/会话惰性加载；失败一次即锁定（缺件是正常降级，不反复重试）。
    private func recRuntime() async -> RecRuntime? {
        if let rec { return rec }
        guard !recUnavailable else { return nil }
        guard let loaded = await OCRModelStore.shared.load() else {
            recUnavailable = true
            return nil
        }
        do {
            let session = try ONNXRuntimeSession(modelData: loaded.modelData,
                                                 inputName: loaded.asset.inputName,
                                                 outputName: loaded.asset.outputName)
            let runtime = RecRuntime(session: session, asset: loaded.asset,
                                     vocabulary: loaded.vocabulary,
                                     displayName: loaded.displayName,
                                     modelSHA256: loaded.modelSHA256)
            rec = runtime
            return runtime
        } catch {
            recUnavailable = true
            return nil
        }
    }

    /// 诊断轨迹：逐块对照 + 一行汇总；不参与交付。
    ///
    /// 每个块可能消费多行 Paddle；逐行指标按 `blockPaddleRects` 的**单行框**查，
    /// 不能用块级 union bbox 查（union 与任何单行框都不相等，指标会全为 0）。
    private static func trace(merged: PaddleLayoutMerge.Result,
                              detection: PaddleTextDetector.Detection,
                              stats: [String: RecStat],
                              recModel: String?, recModelSHA256: String?, recLatencyMs: Double,
                              visionConfidences: [Double],
                              failedLines: Int, note: String?) -> OCRDebugTrace {
        var lines: [OCRDebugTrace.Line] = []
        for (index, block) in merged.layout.blocks.enumerated() {
            let blockStats = merged.blockPaddleRects[index].compactMap { stats[geometryKey($0)] }
            func sum(_ keyPath: KeyPath<RecStat, Double>) -> Double {
                blockStats.reduce(0) { $0 + $1[keyPath: keyPath] }
            }
            func sumInt(_ keyPath: KeyPath<RecStat, Int>) -> Int {
                blockStats.reduce(0) { $0 + $1[keyPath: keyPath] }
            }
            lines.append(.init(
                lineIndex: index,
                bbox: [block.bbox.x, block.bbox.y, block.bbox.width, block.bbox.height],
                visionText: merged.blockVisionText[index],
                paddleText: merged.blockPaddleText[index] ?? "",
                visionConfidence: index < visionConfidences.count ? visionConfidences[index] : 0,
                paddleConfidence: merged.blockPaddleConfidence[index] ?? 0,
                cropWidth: sum(\.cropWidth), cropHeight: sum(\.cropHeight),
                recWidth: sumInt(\.recWidth), timesteps: sumInt(\.timesteps),
                latencyMs: sum(\.latencyMs),
                error: merged.blockPaddleText[index] == nil ? "vision-fallback" : nil))
        }
        let totalLatencyMs = detection.latencyMs + recLatencyMs
        lines.append(.init(
            lineIndex: -1, bbox: [],
            visionText: "det=\(detection.boxes.count) replaced=\(merged.replaced) "
                + "keptVision=\(merged.keptVision) appended=\(merged.appended) "
                + "recFailed=\(failedLines)",
            paddleText: "", visionConfidence: 0, paddleConfidence: 0,
            cropWidth: 0, cropHeight: 0, recWidth: 0, timesteps: 0,
            latencyMs: totalLatencyMs, error: note))
        return OCRDebugTrace(model: recModel ?? detection.model,
                             modelSHA256: recModelSHA256 ?? detection.modelSHA256,
                             detModel: detection.model, detModelSHA256: detection.modelSHA256,
                             engine: "PP-OCRv6 det+rec/onnxruntime",
                             totalLatencyMs: totalLatencyMs, lines: lines)
    }

    /// 诊断开启时把「为什么没走 Paddle」写进轨迹，交付结果不变。
    ///
    /// 降级页仍逐行写入 **Vision 实际交付文本**：旧实现只写一条汇总行
    /// （lineIndex -1），采集层按 lineIndex ≥ 0 过滤后得到空页/空 deliveredText，
    /// 恰好把「Paddle 缺件」这一最需要诊断的失败模式记成「整页无字」。
    private static func annotated(_ base: ImageInputRules.Recognition,
                                  note: String) -> ImageInputRules.Recognition {
        var lines: [OCRDebugTrace.Line] = []
        if let layout = base.layout, layout.blocks.count == base.lines.count {
            lines = zip(layout.blocks, base.lines).enumerated().map { index, pair in
                let (block, text) = pair
                return OCRDebugTrace.Line(
                    lineIndex: index,
                    bbox: [block.bbox.x, block.bbox.y, block.bbox.width, block.bbox.height],
                    visionText: text, paddleText: "", visionConfidence: block.confidence,
                    paddleConfidence: 0, cropWidth: 0, cropHeight: 0, recWidth: 0,
                    timesteps: 0, latencyMs: 0, error: "vision-fallback")
            }
        } else {
            lines = base.lines.enumerated().map { index, text in
                OCRDebugTrace.Line(
                    lineIndex: index, bbox: [], visionText: text, paddleText: "",
                    visionConfidence: 0, paddleConfidence: 0, cropWidth: 0, cropHeight: 0,
                    recWidth: 0, timesteps: 0, latencyMs: 0, error: "vision-fallback")
            }
        }
        lines.append(.init(lineIndex: -1, bbox: [], visionText: "",
                           paddleText: "", visionConfidence: 0,
                           paddleConfidence: 0, cropWidth: 0,
                           cropHeight: 0, recWidth: 0, timesteps: 0,
                           latencyMs: 0, error: note))
        let trace = OCRDebugTrace(model: "PP-OCRv6", modelSHA256: "",
                                  engine: "paddle-unavailable", totalLatencyMs: 0,
                                  lines: lines)
        return ImageInputRules.Recognition(lines: base.lines, confidence: base.confidence,
                                           layout: base.layout, debugTrace: trace)
    }

    private static func geometryKey(_ rect: LayoutRect) -> String {
        let scale = 1_000_000.0
        return "\(Int((rect.x * scale).rounded())):\(Int((rect.y * scale).rounded())):"
            + "\(Int((rect.width * scale).rounded())):\(Int((rect.height * scale).rounded()))"
    }
}
#endif
