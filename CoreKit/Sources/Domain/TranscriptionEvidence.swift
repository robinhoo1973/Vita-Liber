import Foundation

/// 识别证据（2026-11-03 round3 P0-B；tech-spec §5.13 落链）：引擎**原生**给出的逐词证据。
///
/// **为什么需要**：此前各引擎只回传一段文本——sherpa 只读 `result.text`，iOS 26 轨的最终
/// 置信度写死为常数——任何置信度门槛、复核排序、多引擎融合或离线评测都没有可用输入。
///
/// **零持久化**：与 `TranscriptionResult` 同为纯值对象，不含音频、URL、Data 或文件句柄；
/// 只在一次按压的调用栈内存活，从不落盘（FR17.7 / data-flow §11.4）。
///
/// **置信度诚实**：`TranscriptionToken.confidence` 是引擎原生值、未经校准，不同引擎之间
/// **不可直接比较**（各架构置信度尺度不同）；跨引擎比较只能经离线校准表（融合层）。
/// 引擎不给逐词置信度时必须如实标 `.unavailable`，不得用常数冒充。
public enum TranscriptionConfidenceKind: String, Sendable, Equatable, Codable {
    /// 引擎没有给出逐词置信度（Qwen3-ASR / SenseVoice / CTC 家族）。
    case unavailable
    /// 引擎原生、未校准的逐词置信度（Apple 段置信度 / sherpa transducer `ys_log_probs` 换算）。
    case engineNative
}

/// 引擎给出的一个词元及其原生证据。
public struct TranscriptionToken: Sendable, Equatable {
    /// 词元原文（Apple 段 substring / sherpa token 去掉分词前缀符号后的文本）。
    public var text: String
    /// 相对本次按压音频起点的开始时间（秒）；引擎不给时为 nil。
    public var start: TimeInterval?
    /// 持续时长（秒）；引擎不给时为 nil。
    public var duration: TimeInterval?
    /// 引擎原生置信度，归一到 0…1、未校准；nil = 引擎未给。
    public var confidence: Double?
    /// 引擎原生替代写法（Apple `alternativeSubstrings`），不含 `text` 本身。
    public var alternatives: [String]

    public init(text: String, start: TimeInterval? = nil, duration: TimeInterval? = nil,
                confidence: Double? = nil, alternatives: [String] = []) {
        self.text = text
        self.start = start
        self.duration = duration
        self.confidence = confidence.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        self.alternatives = alternatives
    }
}

/// 一个引擎对本次按压的原生输出（润色、融合之前）。
public struct TranscriptionHypothesis: Sendable, Equatable {
    /// 产出该假设的引擎标识，与 `TranscriptionResult.engineID` 同一命名空间
    /// （如 `classic`、`qwen3`）；同一引擎的不同语言实例以 `engine:locale` 区分（如 `classic:en-US`）。
    public var engineID: String
    /// 引擎实际使用的 locale；混说模型由模型自判语种时为 nil。
    public var localeIdentifier: String?
    /// 引擎原生 1-best 全文（未经润色）。
    public var text: String
    /// 逐词证据；引擎不提供 token 时为空。
    public var tokens: [TranscriptionToken]
    /// `tokens` 中置信度的来源性质。
    public var confidenceKind: TranscriptionConfidenceKind
    /// 引擎原生语种标签（如 SenseVoice 的 `lang`）；nil = 未给。
    public var languageTag: String?
    /// 引擎原生 n-best 中除 1-best 以外的全文（Apple `transcriptions`），保持引擎排序。
    public var alternativeTexts: [String]

    public init(engineID: String, localeIdentifier: String? = nil, text: String,
                tokens: [TranscriptionToken] = [], confidenceKind: TranscriptionConfidenceKind = .unavailable,
                languageTag: String? = nil, alternativeTexts: [String] = []) {
        self.engineID = engineID
        self.localeIdentifier = localeIdentifier
        self.text = text
        self.tokens = tokens
        self.confidenceKind = confidenceKind
        self.languageTag = languageTag
        self.alternativeTexts = alternativeTexts
    }
}
