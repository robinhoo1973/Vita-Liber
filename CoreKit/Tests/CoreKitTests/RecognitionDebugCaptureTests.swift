import Foundation
import Testing
@testable import Domain

// binds: SU-M15-RECDEBUG — 真机识别调试采集（2026-11-04）：多引擎文本 → input/output 结构、交付不变、what-if 不交付
/// 识别调试采集纯 Domain：ASR/OCR 共用文本层结构，确定性，Linux 可跑。
@Suite("SU-M15-RECDEBUG · 真机识别调试采集（多引擎文本 → 只提示结果 + what-if）")
struct RecognitionDebugCaptureTests {
    typealias C = RecognitionDebugCapture

    static func asrInput(primary: String, zh: String, en: String) -> C.Input {
        C.Input(captureID: "cap", modality: .asr, createdAt: "2026-11-04T00:00:00Z",
                deliveredText: primary, segments: [
                    C.Segment(index: 0, hypotheses: [
                        C.Hypothesis(engineID: "qwen3", sourceGroup: "sherpa", role: .primary, text: primary),
                        C.Hypothesis(engineID: "apple-zh-CN", sourceGroup: "apple-speech", role: .secondary,
                                     locale: "zh-CN", text: zh),
                        C.Hypothesis(engineID: "apple-en-US", sourceGroup: "apple-speech", role: .secondary,
                                     locale: "en-US", text: en),
                    ])
                ])
    }

    @Test("只提示文本恒等于主轨原文（交付不变），两副轨一致反对时 what-if 才改写")
    func reviewOnlyKeepsPrimaryWhatIfMayRewrite() {
        let input = Self.asrInput(primary: "今天头通", zh: "今天头痛", en: "")
        let output = C.fuse(input)
        #expect(output.reviewOnlyText == "今天头通")
        #expect(output.deliveredText == "今天头通")
        #expect(output.segments.first?.whatIfEdits.allSatisfy { $0.original != $0.replacement } == true)
        #expect(output.schema == C.outputSchema)
        #expect(output.calibration == C.calibrationLabel)
    }

    @Test("否定词分歧永不在 what-if 中自动改写，只进争议")
    func negationNeverRewritten() {
        let output = C.fuse(Self.asrInput(primary: "我不发热", zh: "我没发热", en: ""))
        #expect(output.whatIfText == "我不发热")
        #expect(output.editCount == 0)
        #expect(output.disputedSegmentCount == 1)
    }

    @Test("全体一致 → unanimous 且无争议")
    func unanimousSegment() {
        let input = C.Input(captureID: "c", modality: .asr, createdAt: "t", deliveredText: "血压正常",
                            segments: [C.Segment(index: 0, hypotheses: [
                                C.Hypothesis(engineID: "a", sourceGroup: "a", role: .primary, text: "血压正常"),
                                C.Hypothesis(engineID: "b", sourceGroup: "b", role: .secondary, text: "血压正常 "),
                            ])])
        let segment = C.fuse(input).segments[0]
        #expect(segment.unanimous)
        #expect(segment.disputes.isEmpty)
    }

    @Test("主轨失败 → 不替用户挑副轨，记 primary-unavailable")
    func primaryFailureDoesNotPromoteSecondary() {
        let input = C.Input(captureID: "c", modality: .ocr, createdAt: "t", deliveredText: "",
                            segments: [C.Segment(index: 3, hypotheses: [
                                C.Hypothesis(engineID: "p", sourceGroup: "p", role: .primary, status: .failed,
                                             reason: "crop-failed", text: ""),
                                C.Hypothesis(engineID: "v", sourceGroup: "v", role: .secondary, text: "白细胞"),
                            ])])
        let segment = C.fuse(input).segments[0]
        #expect(segment.note == "primary-unavailable")
        #expect(segment.reviewOnlyText.isEmpty)
        #expect(segment.whatIfText.isEmpty)
    }

    @Test("Apple 英文实例只在拉丁/数字/符号列投票")
    func englishLocaleProducibleScripts() {
        let scripts = C.producibleScripts(for: Self.asrInput(primary: "a", zh: "b", en: "c").segments)
        #expect(scripts["apple-en-US"] == [.latin, .digit, .other])
        #expect(scripts["apple-zh-CN"] == nil)
        #expect(scripts["qwen3"] == nil)
    }

    @Test("统一先验过融合门槛下限（每格错误数 ≥ minimumErrors）")
    func uniformCalibrationIsUsable() {
        let calibration = C.uniformCalibration(engineIDs: ["a", "b", "a"])
        #expect(calibration.releasePassed)
        #expect(calibration.cells.count == 2 * HypothesisFusionScript.allCases.count
                * HypothesisFusionTokenClass.allCases.count)
        #expect(calibration.cells.allSatisfy {
            $0.total >= HypothesisFusionCalibration.minimumTokens
                && $0.total - $0.correct >= HypothesisFusionCalibration.minimumErrors
        })
    }

    @Test("OCR：Paddle 为主轨、Vision 为副轨，行序与框保留，按行换行拼接")
    func ocrSegmentsFromTrace() {
        let trace = OCRDebugTrace(model: "m", modelSHA256: "", engine: "e", totalLatencyMs: 1, lines: [
            .init(lineIndex: -1, bbox: [], visionText: "", paddleText: "", visionConfidence: 0,
                  paddleConfidence: 0, cropWidth: 0, cropHeight: 0, recWidth: 0, timesteps: 0, latencyMs: 0,
                  error: "model-missing"),
            .init(lineIndex: 0, bbox: [0.1, 0.1, 0.5, 0.05], visionText: "白细胞计数", paddleText: "白细胞计数",
                  visionConfidence: 0.9, paddleConfidence: 0.95, cropWidth: 100, cropHeight: 20, recWidth: 320,
                  timesteps: 40, latencyMs: 3),
            .init(lineIndex: 1, bbox: [0.1, 0.2, 0.5, 0.05], visionText: "血红蛋白", paddleText: "血红蛋自",
                  visionConfidence: 0.9, paddleConfidence: 0.8, cropWidth: 100, cropHeight: 20, recWidth: 320,
                  timesteps: 40, latencyMs: 3),
        ])
        let segments = C.ocrSegments(from: trace)
        #expect(segments.map(\.index) == [0, 1])
        #expect(segments[0].hypotheses.map(\.role) == [.primary, .secondary])
        #expect(segments[0].bbox == [0.1, 0.1, 0.5, 0.05])
        let output = C.fuse(C.Input(captureID: "o", modality: .ocr, createdAt: "t",
                                    deliveredText: "白细胞计数\n血红蛋白", segments: segments))
        #expect(output.reviewOnlyText == "白细胞计数\n血红蛋自")
        #expect(output.segments[0].unanimous)
    }

    @Test("采集目录名：时间序 + 模态 + id6；裁剪只动本布局目录")
    func folderLayoutAndPrune() {
        let id = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
        let name = C.captureFolderName(modality: .asr, date: Date(timeIntervalSince1970: 0), captureID: id,
                                       timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "19700101-000000-asr-abcdef")
        #expect(C.isCaptureFolderName(name))
        #expect(!C.isCaptureFolderName("我的文件"))
        #expect(!C.isCaptureFolderName("19700101-000000-png-abcdef"))
        let names = ["19700101-000002-ocr-aaaaaa", "19700101-000001-asr-bbbbbb", "notes.txt",
                     "19700101-000003-asr-cccccc"]
        #expect(C.capturesToPrune(names, keeping: 2) == ["19700101-000001-asr-bbbbbb"])
        #expect(C.capturesToPrune(names, keeping: 5).isEmpty)
    }

    @Test("input/output JSON 往返稳定")
    func jsonRoundTrip() throws {
        let input = Self.asrInput(primary: "Yes 你说得对", zh: "也是你说得对", en: "Yes")
        let decodedInput = try JSONDecoder().decode(C.Input.self, from: C.encode(input))
        #expect(decodedInput == input)
        let output = C.fuse(input)
        let decodedOutput = try JSONDecoder().decode(C.Output.self, from: C.encode(output))
        #expect(decodedOutput == output)
    }

    @Test("TranscriptionHypothesis 往返保留逐词证据")
    func transcriptionHypothesisRoundTrip() {
        let source = TranscriptionHypothesis(
            engineID: "classic:zh-CN", localeIdentifier: "zh-CN", text: "头痛",
            tokens: [TranscriptionToken(text: "头痛", start: 0.1, duration: 0.4, confidence: 0.8,
                                        alternatives: ["头疼"])],
            confidenceKind: .engineNative, alternativeTexts: ["头疼"])
        let captured = C.Hypothesis(source, sourceGroup: "apple-speech", role: .primary)
        #expect(captured.confidence == 0.8)
        #expect(captured.transcriptionHypothesis == source)
    }
}
