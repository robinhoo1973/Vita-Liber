import Foundation

/// OCR 逐行对照诊断（2026-11-03 真机调参批；2026-11-05 Paddle 主轨后更新语义）。
///
/// 交付文字以 PP-OCRv6 rec 为准，Vision 提供版式与兜底；该结构记录
/// 「交付行（Paddle 命中时）/ Vision 原文」的逐行对照、裁剪几何与时延，
/// 供业主在“文件”App 的会话目录取回后调参。`model`/`modelSHA256` 是
/// **产出交付文字的 rec 模型**；det 模型身份见 `detModel`/`detModelSHA256`。
/// 不参与任何医疗事实、不改变 D 级语义、不含图片/音频。
public struct OCRDebugTrace: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable {
        public var lineIndex: Int
        public var bbox: [Double]
        public var visionText: String
        /// 交付文本（第三源共识选择之后）。原文见 `rawPaddleText`。
        public var paddleText: String
        /// 选择器之前的 Paddle rec 原文；nil = 旧轨迹/降级页。
        public var rawPaddleText: String?
        /// CnOCR 第三源原文；nil = 第三源缺件或该行失败。
        public var cnocrText: String?
        public var visionConfidence: Double
        public var paddleConfidence: Double
        public var cropWidth: Double
        public var cropHeight: Double
        public var recWidth: Int
        public var timesteps: Int
        public var latencyMs: Double
        public var error: String?

        public init(lineIndex: Int, bbox: [Double], visionText: String, paddleText: String,
                    rawPaddleText: String? = nil, cnocrText: String? = nil,
                    visionConfidence: Double, paddleConfidence: Double,
                    cropWidth: Double, cropHeight: Double, recWidth: Int,
                    timesteps: Int, latencyMs: Double, error: String? = nil) {
            self.lineIndex = lineIndex
            self.bbox = bbox
            self.visionText = visionText
            self.paddleText = paddleText
            self.rawPaddleText = rawPaddleText
            self.cnocrText = cnocrText
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
    /// 产出交付文字的 **rec** 模型名/版本（Paddle 主轨：`family@version`）。
    public var model: String
    public var modelSHA256: String
    /// det 模型身份（Paddle 主轨）；Vision-only 降级时为 nil。
    public var detModel: String?
    public var detModelSHA256: String?
    /// 第三识别源身份（CnOCR）；未随包/未启用时为 nil。
    public var thirdModel: String?
    public var thirdModelSHA256: String?
    public var engine: String
    public var totalLatencyMs: Double
    public var lines: [Line]

    public init(schemaVersion: Int = 3, pageIndex: Int = 0, model: String, modelSHA256: String,
                detModel: String? = nil, detModelSHA256: String? = nil,
                thirdModel: String? = nil, thirdModelSHA256: String? = nil,
                engine: String, totalLatencyMs: Double, lines: [Line]) {
        self.schemaVersion = schemaVersion
        self.pageIndex = pageIndex
        self.model = model
        self.modelSHA256 = modelSHA256
        self.detModel = detModel
        self.detModelSHA256 = detModelSHA256
        self.thirdModel = thirdModel
        self.thirdModelSHA256 = thirdModelSHA256
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
