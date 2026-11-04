import Foundation

/// 真机识别调试采集（2026-11-04 业主：多模型识别文本后处理调参数据）。
///
/// 处理对象是**文本**：ASR 与 OCR 共用同一结构——每个「段」（ASR 一次按压 = 1 段；
/// OCR 一行 = 1 段）挂多个引擎的原生假设。采集分两步落盘到会话目录
/// `recognition-debug/<采集目录>/`：融合前写 `input.json`（各引擎原文 + 原生证据），
/// 融合后写 `output.json`（只提示结果 + 门控改写 what-if）。
///
/// 安全边界：只用于调试回传，**不改变交付文本**（交付恒为生产主轨原文，P2a 只提示）；
/// what-if 改写只落文件、永不进入聊天/抽取/事实链（BR-003）。校准使用统一先验
/// `uniform-debug-prior`（金样未建立前的占位，结论只作对比参考）。
public enum RecognitionDebugCapture {
    public static let inputSchema = "vitaliber.recognition-debug.input/v1"
    public static let outputSchema = "vitaliber.recognition-debug.output/v1"
    public static let calibrationLabel = "uniform-debug-prior"
    /// 会话目录下的调试子目录名。
    public static let folderName = "recognition-debug"
    /// 每个会话保留的最近采集数（防无限增长；业主回传前可随时拷走）。
    public static let retainedCapturesPerConversation = 50

    public enum Modality: String, Sendable, Equatable, Codable {
        case asr
        case ocr
    }

    /// 引擎原生词元证据。
    public struct Token: Sendable, Equatable, Codable {
        public var text: String
        public var start: Double?
        public var duration: Double?
        public var confidence: Double?
        public var alternatives: [String]

        public init(text: String, start: Double? = nil, duration: Double? = nil,
                    confidence: Double? = nil, alternatives: [String] = []) {
            self.text = text
            self.start = start
            self.duration = duration
            self.confidence = confidence
            self.alternatives = alternatives
        }
    }

    /// 一个引擎对一个段的原生输出。
    public struct Hypothesis: Sendable, Equatable, Codable {
        public enum Role: String, Sendable, Equatable, Codable {
            /// 生产主轨（ASR：按硬件/设置选出的引擎；OCR：PP-OCRv6）。
            case primary
            /// 参与对照的副轨（ASR：Apple 中文 / Apple 英文；OCR：Apple Vision）。
            case secondary
        }

        public enum Status: String, Sendable, Equatable, Codable {
            case recognized
            case failed
            /// 未运行（系统不支持离线识别、与主轨同源重复等），见 `reason`。
            case skipped
        }

        public var engineID: String
        /// 相关组：同组假设不是独立投票（同一 Apple 识别栈的不同语言实例仍记各自组）。
        public var sourceGroup: String
        public var role: Role
        public var status: Status
        public var reason: String?
        public var locale: String?
        public var elapsedMs: Double?
        public var text: String
        /// 引擎给出的整体置信度（OCR 行置信度 / ASR 平均）；nil = 未给。
        public var confidence: Double?
        public var confidenceKind: String?
        public var languageTag: String?
        public var tokens: [Token]
        public var alternativeTexts: [String]

        public init(engineID: String, sourceGroup: String, role: Role, status: Status = .recognized,
                    reason: String? = nil, locale: String? = nil, elapsedMs: Double? = nil,
                    text: String, confidence: Double? = nil, confidenceKind: String? = nil,
                    languageTag: String? = nil, tokens: [Token] = [], alternativeTexts: [String] = []) {
            self.engineID = engineID
            self.sourceGroup = sourceGroup
            self.role = role
            self.status = status
            self.reason = reason
            self.locale = locale
            self.elapsedMs = elapsedMs
            self.text = text
            self.confidence = confidence
            self.confidenceKind = confidenceKind
            self.languageTag = languageTag
            self.tokens = tokens
            self.alternativeTexts = alternativeTexts
        }

        /// 由引擎证据面（`TranscriptionHypothesis`）转换。
        public init(_ hypothesis: TranscriptionHypothesis, sourceGroup: String, role: Role,
                    elapsedMs: Double? = nil) {
            let confidences = hypothesis.tokens.compactMap(\.confidence)
            self.init(engineID: hypothesis.engineID, sourceGroup: sourceGroup, role: role,
                      locale: hypothesis.localeIdentifier, elapsedMs: elapsedMs, text: hypothesis.text,
                      confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
                      confidenceKind: hypothesis.confidenceKind.rawValue,
                      languageTag: hypothesis.languageTag,
                      tokens: hypothesis.tokens.map {
                          Token(text: $0.text, start: $0.start, duration: $0.duration,
                                confidence: $0.confidence, alternatives: $0.alternatives)
                      },
                      alternativeTexts: hypothesis.alternativeTexts)
        }

        /// 转回融合内核输入。
        public var transcriptionHypothesis: TranscriptionHypothesis {
            TranscriptionHypothesis(
                engineID: engineID, localeIdentifier: locale, text: text,
                tokens: tokens.map {
                    TranscriptionToken(text: $0.text, start: $0.start, duration: $0.duration,
                                       confidence: $0.confidence, alternatives: $0.alternatives)
                },
                confidenceKind: confidenceKind.flatMap(TranscriptionConfidenceKind.init(rawValue:)) ?? .unavailable,
                languageTag: languageTag, alternativeTexts: alternativeTexts)
        }

        var isUsable: Bool {
            status == .recognized && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 一个段：ASR 一次按压 / OCR 一行。
    public struct Segment: Sendable, Equatable, Codable {
        public var index: Int
        /// OCR 行框（左上原点归一化 x, y, w, h）；ASR 为 nil。
        public var bbox: [Double]?
        public var hypotheses: [Hypothesis]

        public init(index: Int, bbox: [Double]? = nil, hypotheses: [Hypothesis]) {
            self.index = index
            self.bbox = bbox
            self.hypotheses = hypotheses
        }
    }

    /// 融合前快照（`input.json`）。
    public struct Input: Sendable, Equatable, Codable {
        public var schema: String
        public var captureID: String
        public var modality: Modality
        public var createdAt: String
        /// 设备/系统/App 版本等环境信息（键值对，便于横向比较）。
        public var environment: [String: String]
        /// 请求参数（语言集、混说模式、热词数、页序号等）。
        public var request: [String: String]
        /// 同目录内的媒体文件名（音频 / 页图）。
        public var mediaFiles: [String]
        /// 生产实际交付给用户的文本（主轨原文；调试采集绝不改变它）。
        public var deliveredText: String
        public var segments: [Segment]

        public init(captureID: String, modality: Modality, createdAt: String,
                    environment: [String: String] = [:], request: [String: String] = [:],
                    mediaFiles: [String] = [], deliveredText: String, segments: [Segment]) {
            self.schema = RecognitionDebugCapture.inputSchema
            self.captureID = captureID
            self.modality = modality
            self.createdAt = createdAt
            self.environment = environment
            self.request = request
            self.mediaFiles = mediaFiles
            self.deliveredText = deliveredText
            self.segments = segments
        }
    }

    public struct Candidate: Sendable, Equatable, Codable {
        public var surface: String?
        public var engineIDs: [String]
        public var score: Double
        public var isPrimary: Bool
    }

    public struct Dispute: Sendable, Equatable, Codable {
        public var utf16Start: Int
        public var utf16End: Int
        public var primarySurface: String?
        public var reason: String
        public var candidates: [Candidate]
    }

    public struct Edit: Sendable, Equatable, Codable {
        public var kind: String
        public var utf16Start: Int
        public var utf16End: Int
        public var original: String
        public var replacement: String
        public var supportingEngineIDs: [String]
        public var margin: Double
    }

    public struct PairObservation: Sendable, Equatable, Codable {
        public var primaryEngineID: String
        public var secondaryEngineID: String
        public var disagreements: Int
        public var columns: Int
    }

    /// 一个段的融合结果。
    public struct SegmentResult: Sendable, Equatable, Codable {
        public var index: Int
        public var primaryEngineID: String?
        public var secondaryEngineIDs: [String]
        /// 所有可用假设逐字一致（去首尾空白）。
        public var unanimous: Bool
        /// 只提示模式文本（恒等于主轨原文）。
        public var reviewOnlyText: String
        public var disputes: [Dispute]
        /// 门控改写 what-if 文本（**不交付**，仅供调参对比）。
        public var whatIfText: String
        public var whatIfEdits: [Edit]
        public var fallback: String?
        public var note: String?
        public var pairObservations: [PairObservation]
    }

    /// 融合后结果（`output.json`）。
    public struct Output: Sendable, Equatable, Codable {
        public var schema: String
        public var captureID: String
        public var modality: Modality
        public var calibration: String
        public var tau: Double
        public var deliveredText: String
        /// 各段只提示文本按段序拼接（OCR 按行换行）。
        public var reviewOnlyText: String
        /// 各段 what-if 文本按段序拼接（**不交付**）。
        public var whatIfText: String
        public var segmentCount: Int
        public var disputedSegmentCount: Int
        public var editCount: Int
        public var segments: [SegmentResult]
        public var elapsedMs: Double?
    }

    // MARK: - 融合

    /// 各引擎可产出的脚本（键 = engineID）；未列出 = 全部脚本。
    /// Apple 英文实例只产拉丁/数字/符号——在汉字列弃权，不把英文转写当作对汉字的反对票。
    public static func producibleScripts(for segments: [Segment]) -> [String: Set<HypothesisFusionScript>] {
        var result: [String: Set<HypothesisFusionScript>] = [:]
        for hypothesis in segments.flatMap(\.hypotheses) {
            guard let locale = hypothesis.locale?.lowercased(), locale.hasPrefix("en") else { continue }
            result[hypothesis.engineID] = [.latin, .digit, .other]
        }
        return result
    }

    /// 统一先验校准：每个引擎 × 脚本 × 词类同权（900/1000）。只用于调试 what-if，
    /// 生产门控（`HypothesisFusionGate`）不接受它——它没有金样评测来源。
    public static func uniformCalibration(engineIDs: [String]) -> HypothesisFusionCalibration {
        var cells: [HypothesisFusionCalibration.Cell] = []
        for engineID in Set(engineIDs).sorted() {
            for script in HypothesisFusionScript.allCases {
                for tokenClass in HypothesisFusionTokenClass.allCases {
                    cells.append(.init(engineID: engineID, script: script, tokenClass: tokenClass,
                                       correct: 900, total: 1000))
                }
            }
        }
        return HypothesisFusionCalibration(version: calibrationLabel, corpusSize: 0, codeSwitchedCount: 0,
                                           releasePassed: true, cells: cells)
    }

    /// 对采集输入做融合：只提示（交付语义）+ 门控改写 what-if（不交付）。
    public static func fuse(_ input: Input, tau: Double = 1.0, protectedTerms: [String] = []) -> Output {
        let engineIDs = input.segments.flatMap(\.hypotheses).map(\.engineID)
        let calibration = uniformCalibration(engineIDs: engineIDs)
        let scripts = producibleScripts(for: input.segments)
        let results = input.segments.map {
            fuse(segment: $0, calibration: calibration, scripts: scripts, tau: tau,
                 protectedTerms: protectedTerms)
        }
        let separator = input.modality == .ocr ? "\n" : ""
        return Output(
            schema: outputSchema, captureID: input.captureID, modality: input.modality,
            calibration: calibrationLabel, tau: tau, deliveredText: input.deliveredText,
            reviewOnlyText: results.map(\.reviewOnlyText).joined(separator: separator),
            whatIfText: results.map(\.whatIfText).joined(separator: separator),
            segmentCount: results.count,
            disputedSegmentCount: results.filter { !$0.disputes.isEmpty }.count,
            editCount: results.reduce(0) { $0 + $1.whatIfEdits.count },
            segments: results, elapsedMs: nil)
    }

    static func fuse(segment: Segment, calibration: HypothesisFusionCalibration,
                     scripts: [String: Set<HypothesisFusionScript>], tau: Double,
                     protectedTerms: [String]) -> SegmentResult {
        let usable = segment.hypotheses.filter(\.isUsable)
        let normalized = Set(usable.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
        let unanimous = usable.count >= 2 && normalized.count == 1
        guard let primary = segment.hypotheses.first(where: { $0.role == .primary }), primary.isUsable else {
            // 主轨不可用：不替用户挑副轨（交付语义不变），只记录。
            return SegmentResult(index: segment.index, primaryEngineID: nil,
                                 secondaryEngineIDs: usable.map(\.engineID), unanimous: unanimous,
                                 reviewOnlyText: "", disputes: [], whatIfText: "", whatIfEdits: [],
                                 fallback: nil, note: "primary-unavailable", pairObservations: [])
        }
        let secondaries = usable.filter { $0.role == .secondary && $0.engineID != primary.engineID }
        let primaryHypothesis = primary.transcriptionHypothesis
        let secondaryHypotheses = secondaries.map(\.transcriptionHypothesis)
        let review = HypothesisFusion.fuse(
            primary: primaryHypothesis, secondaries: secondaryHypotheses, calibration: calibration,
            options: HypothesisFusionOptions(mode: .reviewOnly, tau: tau, protectedTerms: protectedTerms,
                                             producibleScripts: scripts))
        let whatIf = HypothesisFusion.fuse(
            primary: primaryHypothesis, secondaries: secondaryHypotheses, calibration: calibration,
            options: HypothesisFusionOptions(mode: .gatedRewrite, tau: tau, protectedTerms: protectedTerms,
                                             producibleScripts: scripts))
        return SegmentResult(
            index: segment.index, primaryEngineID: primary.engineID,
            secondaryEngineIDs: secondaries.map(\.engineID), unanimous: unanimous,
            reviewOnlyText: review.text,
            disputes: review.disputes.map(dispute),
            whatIfText: whatIf.text,
            whatIfEdits: whatIf.edits.map(edit),
            fallback: review.fallback?.rawValue, note: nil,
            pairObservations: review.pairObservations.map {
                PairObservation(primaryEngineID: $0.primaryEngineID, secondaryEngineID: $0.secondaryEngineID,
                                disagreements: $0.disagreements, columns: $0.columns)
            })
    }

    private static func dispute(_ value: HypothesisFusionDispute) -> Dispute {
        Dispute(utf16Start: value.utf16Range.lowerBound, utf16End: value.utf16Range.upperBound,
                primarySurface: value.primarySurface, reason: value.reason.rawValue,
                candidates: value.candidates.map {
                    Candidate(surface: $0.surface, engineIDs: $0.engineIDs, score: $0.score,
                              isPrimary: $0.isPrimary)
                })
    }

    private static func edit(_ value: HypothesisFusionEdit) -> Edit {
        Edit(kind: value.kind.rawValue, utf16Start: value.utf16Range.lowerBound,
             utf16End: value.utf16Range.upperBound, original: value.original,
             replacement: value.replacement, supportingEngineIDs: value.supportingEngineIDs,
             margin: value.margin)
    }

    // MARK: - 布局与编码

    /// 采集目录名：`yyyyMMdd-HHmmss-<asr|ocr>-<id6>`（字典序 = 时间序，便于裁剪最旧）。
    public static func captureFolderName(modality: Modality, date: Date, captureID: UUID,
                                         timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let id6 = String(captureID.uuidString.lowercased().prefix(6))
        return "\(formatter.string(from: date))-\(modality.rawValue)-\(id6)"
    }

    /// 是否本布局的采集目录名（裁剪时只删本布局目录，绝不误删用户文件）。
    public static func isCaptureFolderName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].count == 8, parts[1].count == 6, parts[3].count == 6,
              parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber),
              parts[2] == Modality.asr.rawValue || parts[2] == Modality.ocr.rawValue else { return false }
        return parts[3].allSatisfy { $0.isHexDigit }
    }

    /// 超出保留数时应删除的最旧采集目录（输入为子目录名全集）。
    public static func capturesToPrune(_ names: [String],
                                       keeping: Int = retainedCapturesPerConversation) -> [String] {
        let captures = names.filter(isCaptureFolderName).sorted()
        guard keeping >= 0, captures.count > keeping else { return [] }
        return Array(captures.prefix(captures.count - keeping))
    }

    /// 稳定 JSON 编码（排序键、缩进，便于人工对比与 diff）。
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// OCR：把 Paddle（主轨）与 Vision（副轨）逐行对照转为采集段。
    /// 行由同一 Vision 行框裁剪识别，天然一一对齐，无需再做框匹配。
    public static func ocrSegments(from trace: OCRDebugTrace) -> [Segment] {
        trace.lines.filter { $0.lineIndex >= 0 }.map { line in
            let paddleStatus: Hypothesis.Status = line.error == nil ? .recognized : .failed
            return Segment(index: line.lineIndex, bbox: line.bbox, hypotheses: [
                Hypothesis(engineID: "paddle-ppocrv6-rec", sourceGroup: "paddle", role: .primary,
                           status: paddleStatus, reason: line.error, elapsedMs: line.latencyMs,
                           text: line.paddleText, confidence: line.paddleConfidence,
                           confidenceKind: TranscriptionConfidenceKind.engineNative.rawValue),
                Hypothesis(engineID: "apple-vision", sourceGroup: "apple-vision", role: .secondary,
                           text: line.visionText, confidence: line.visionConfidence,
                           confidenceKind: TranscriptionConfidenceKind.engineNative.rawValue),
            ])
        }
    }
}
