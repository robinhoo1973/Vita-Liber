import Foundation

/// OCR 影子对照诊断（2026-11-03 真机调参批）。
///
/// Vision 始终是输出源；该结构只记录「Vision 行 vs PP-OCRv6 rec 行」的
/// 逐行对照、裁剪几何与时延，供业主在“文件”App 的会话目录取回后调参。
/// 不参与任何医疗事实、不改变 D 级语义、不含图片/音频。
public struct OCRDebugTrace: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable {
        public var lineIndex: Int
        public var bbox: [Double]
        public var visionText: String
        public var paddleText: String
        public var visionConfidence: Double
        public var paddleConfidence: Double
        public var cropWidth: Double
        public var cropHeight: Double
        public var recWidth: Int
        public var timesteps: Int
        public var latencyMs: Double
        public var error: String?

        public init(lineIndex: Int, bbox: [Double], visionText: String, paddleText: String,
                    visionConfidence: Double, paddleConfidence: Double,
                    cropWidth: Double, cropHeight: Double, recWidth: Int,
                    timesteps: Int, latencyMs: Double, error: String? = nil) {
            self.lineIndex = lineIndex
            self.bbox = bbox
            self.visionText = visionText
            self.paddleText = paddleText
            self.visionConfidence = visionConfidence
            self.paddleConfidence = paddleConfidence
            self.cropWidth = cropWidth
            self.cropHeight = cropHeight
            self.recWidth = recWidth
            self.timesteps = timesteps
            self.latencyMs = latencyMs
            self.error = error
        }
    }

    public var schemaVersion: Int
    /// 由 App 层在拿到页序号后回填；识别层不感知多页会话。
    public var pageIndex: Int
    public var model: String
    public var modelSHA256: String
    public var engine: String
    public var totalLatencyMs: Double
    public var lines: [Line]

    public init(schemaVersion: Int = 1, pageIndex: Int = 0, model: String, modelSHA256: String,
                engine: String, totalLatencyMs: Double, lines: [Line]) {
        self.schemaVersion = schemaVersion
        self.pageIndex = pageIndex
        self.model = model
        self.modelSHA256 = modelSHA256
        self.engine = engine
        self.totalLatencyMs = totalLatencyMs
        self.lines = lines
    }

    /// 单行 JSONL，供会话目录 `ocr-debug-*.jsonl` 直接回传。
    public func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),   // try?-ok: 诊断行编码失败只丢日志，不影响识别
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
