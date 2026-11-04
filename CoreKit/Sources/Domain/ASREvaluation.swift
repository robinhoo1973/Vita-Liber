import Foundation

/// ASR「杀手实验」评测工具链（round3 §8 P0-A：同一段录音喂给多个引擎，决定多模融合去留）。
///
/// 本文件：清单与各系统结果的值类型 + 清单校验。指标计算见 `ASREvaluationReport.swift`，
/// 统计（SplitMix64 / 配对 bootstrap / 分位数）见 `ASREvaluationStatistics.swift`，
/// 止损判定见 `ASREvaluationVerdict`，渲染见 `ASREvaluationRendering`。
///
/// **零持久化边界**：本层只处理文本与数字，不读音频、不碰文件系统；运行器（macOS 测试）
/// 把报告写到仓库之外的输出目录。公开仓只放合成示例，**绝不入库真实录音或转写**。
public enum ASREvaluation {

    /// 清单格式版本（JSON `schemaVersion`）。
    public static let manifestSchemaVersion = 1

    /// 分层标签（JSON 取原始值）。
    public enum Tag: String, Sendable, Codable, CaseIterable {
        /// 中英混说。
        case mixed
        /// 含数字/剂量/单位。
        case numeric
        /// 含否定（不/没/未/无/not…）。
        case negation
        /// 含药名。
        case drug
        /// 急救阳性：参考应命中 `EmergencyKeywordRules`（BR-012 召回分母）。
        case emergencyPositive
        /// 急救阴性对照（误报率分母，如「我没有胸痛」之类否定对照）。
        case emergencyNegative
    }

    /// 清单中的一句。
    public struct Utterance: Sendable, Equatable, Codable {
        public var utteranceID: String
        /// 音频相对路径（相对运行器的音频目录；禁止绝对路径与 `..`）。nil = 纯文本语料
        /// （round5 §6 T1：融合核心只消费文本假设 + 参考文本，不要求每条都有音频）。
        public var audioPath: String?
        /// 人工参考转写（评测口径见 `MixedErrorRate`）。
        public var reference: String
        public var tags: [Tag]
        /// 需原样保留的词（药名等，可选）；每个词必须出现在参考中。
        public var protectedTerms: [String]?

        public init(utteranceID: String, audioPath: String? = nil, reference: String, tags: [Tag] = [],
                    protectedTerms: [String]? = nil) {
            self.utteranceID = utteranceID
            self.audioPath = audioPath
            self.reference = reference
            self.tags = tags
            self.protectedTerms = protectedTerms
        }

        public func has(_ tag: Tag) -> Bool { tags.contains(tag) }

        private enum CodingKeys: String, CodingKey {
            case utteranceID, audioPath, reference, tags, protectedTerms
        }

        /// `tags` 可省略（= 无标签）；未知标签值解码失败——拼写错误必须响亮暴露，不得静默丢分层。
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            utteranceID = try container.decode(String.self, forKey: .utteranceID)
            // 缺省 = 纯文本语料（引擎输出在 SystemRun 里，参考在 reference 里）。
            audioPath = try container.decodeIfPresent(String.self, forKey: .audioPath)
            reference = try container.decode(String.self, forKey: .reference)
            tags = try container.decodeIfPresent([Tag].self, forKey: .tags) ?? []
            protectedTerms = try container.decodeIfPresent([String].self, forKey: .protectedTerms)
        }
    }

    /// 评测清单（JSON 顶层对象）。
    public struct Manifest: Sendable, Equatable, Codable {
        public var schemaVersion: Int
        public var utterances: [Utterance]

        public init(schemaVersion: Int = ASREvaluation.manifestSchemaVersion, utterances: [Utterance]) {
            self.schemaVersion = schemaVersion
            self.utterances = utterances
        }
    }

    /// 清单问题（逐条列出，便于业主一次改全）。
    public enum ManifestIssue: Sendable, Equatable {
        case unsupportedSchemaVersion(Int)
        case noUtterances
        case emptyUtteranceID(index: Int)
        case duplicateUtteranceID(String)
        /// 参考为空或只有标点（MER 分母为 0）。
        case emptyReference(String)
        /// 空路径、绝对路径或含 `..`。
        case invalidAudioPath(String)
        case conflictingEmergencyTags(String)
        case protectedTermNotInReference(utteranceID: String, term: String)
    }

    public struct ManifestValidationError: Error, Sendable, Equatable {
        public var issues: [ManifestIssue]
    }

    /// 校验清单；空数组 = 合格。
    public static func validate(_ manifest: Manifest) -> [ManifestIssue] {
        var issues: [ManifestIssue] = []
        if manifest.schemaVersion != manifestSchemaVersion {
            issues.append(.unsupportedSchemaVersion(manifest.schemaVersion))
        }
        if manifest.utterances.isEmpty { issues.append(.noUtterances) }
        var seen = Set<String>()
        for (index, utterance) in manifest.utterances.enumerated() {
            let id = utterance.utteranceID
            if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.emptyUtteranceID(index: index))
            } else if !seen.insert(id).inserted {
                issues.append(.duplicateUtteranceID(id))
            }
            let referenceTokens = MixedErrorRate.tokenize(utterance.reference)
            if referenceTokens.isEmpty { issues.append(.emptyReference(id)) }
            if let audioPath = utterance.audioPath, !isValidRelativePath(audioPath) {
                issues.append(.invalidAudioPath(id))
            }
            if utterance.has(.emergencyPositive) && utterance.has(.emergencyNegative) {
                issues.append(.conflictingEmergencyTags(id))
            }
            for term in utterance.protectedTerms ?? [] {
                let termTokens = MixedErrorRate.tokenize(term)
                if termTokens.isEmpty || ASREvaluation.occurrences(of: termTokens, in: referenceTokens).isEmpty {
                    issues.append(.protectedTermNotInReference(utteranceID: id, term: term))
                }
            }
        }
        return issues
    }

    /// 解码 + 校验；任何问题都抛 `ManifestValidationError`（缺证据不得静默跑出「绿」报告）。
    public static func decodeManifest(from data: Data) throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let issues = validate(manifest)
        guard issues.isEmpty else { throw ManifestValidationError(issues: issues) }
        return manifest
    }

    private static func isValidRelativePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return false }
        return !trimmed.split(separator: "/").contains("..")
    }

    // MARK: - 各系统结果

    /// 单句识别状态。
    public enum UtteranceStatus: String, Sendable, Codable {
        /// 引擎给出了最终文本（可为空串）。
        case recognized
        /// 引擎报错/超时：按**空假设**计分（全删除），不剔除——剔除会让失败反而「改善」MER。
        case failed
        /// 未尝试（音频缺失等）：不计分，只计数。
        case skipped
    }

    /// 一个系统对一句的结果。
    public struct UtteranceResult: Sendable, Equatable, Codable {
        public var utteranceID: String
        public var status: UtteranceStatus
        /// 引擎原生 1-best 全文；`failed`/`skipped` 时为 nil。
        public var hypothesis: String?
        /// 从提交识别到拿到最终结果的墙钟毫秒。
        public var latencyMilliseconds: Double?
        /// 可选：识别期间峰值内存（字节）。Apple 识别在系统进程内执行，本进程测不到，留空。
        public var peakMemoryBytes: Int64?
        /// 失败/跳过原因（人类可读）。
        public var reason: String?
        /// 可选：引擎原生逐词证据（契约 `TranscriptionHypothesis.tokens`），带置信度时进入 AUROC 区分度评估。
        public var tokens: [TranscriptionToken]?

        public init(utteranceID: String, status: UtteranceStatus, hypothesis: String? = nil,
                    latencyMilliseconds: Double? = nil, peakMemoryBytes: Int64? = nil, reason: String? = nil,
                    tokens: [TranscriptionToken]? = nil) {
            self.utteranceID = utteranceID
            self.status = status
            self.hypothesis = hypothesis
            self.latencyMilliseconds = latencyMilliseconds
            self.peakMemoryBytes = peakMemoryBytes
            self.reason = reason
            self.tokens = tokens
        }

        public static func recognized(_ utteranceID: String, hypothesis: String, latencyMilliseconds: Double? = nil,
                                      peakMemoryBytes: Int64? = nil, tokens: [TranscriptionToken]? = nil) -> UtteranceResult {
            UtteranceResult(utteranceID: utteranceID, status: .recognized, hypothesis: hypothesis,
                            latencyMilliseconds: latencyMilliseconds, peakMemoryBytes: peakMemoryBytes, tokens: tokens)
        }

        /// 由契约假设构造：文本取 1-best，逐词证据原样携带（无 token 时为 nil）。
        public static func recognized(_ utteranceID: String, evidence: TranscriptionHypothesis,
                                      latencyMilliseconds: Double? = nil) -> UtteranceResult {
            recognized(utteranceID, hypothesis: evidence.text, latencyMilliseconds: latencyMilliseconds,
                       tokens: evidence.tokens.isEmpty ? nil : evidence.tokens)
        }

        public static func failed(_ utteranceID: String, reason: String,
                                  latencyMilliseconds: Double? = nil) -> UtteranceResult {
            UtteranceResult(utteranceID: utteranceID, status: .failed,
                            latencyMilliseconds: latencyMilliseconds, reason: reason)
        }

        public static func skipped(_ utteranceID: String, reason: String) -> UtteranceResult {
            UtteranceResult(utteranceID: utteranceID, status: .skipped, reason: reason)
        }

        // 契约 `TranscriptionToken` 不是 Codable（共享契约只读）：经私有镜像编解码，不给共享类型追加一致性
        // （他处若日后为其加 Codable，本文件不会撞重复一致性）。
        private struct TokenRecord: Codable {
            var text: String
            var start: Double?
            var duration: Double?
            var confidence: Double?
            var alternatives: [String]?
        }

        private enum CodingKeys: String, CodingKey {
            case utteranceID, status, hypothesis, latencyMilliseconds, peakMemoryBytes, reason, tokens
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            utteranceID = try container.decode(String.self, forKey: .utteranceID)
            status = try container.decode(UtteranceStatus.self, forKey: .status)
            hypothesis = try container.decodeIfPresent(String.self, forKey: .hypothesis)
            latencyMilliseconds = try container.decodeIfPresent(Double.self, forKey: .latencyMilliseconds)
            peakMemoryBytes = try container.decodeIfPresent(Int64.self, forKey: .peakMemoryBytes)
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
            let records = try container.decodeIfPresent([TokenRecord].self, forKey: .tokens)
            tokens = records?.map { record in
                TranscriptionToken(text: record.text, start: record.start, duration: record.duration,
                                   confidence: record.confidence, alternatives: record.alternatives ?? [])
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(utteranceID, forKey: .utteranceID)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(hypothesis, forKey: .hypothesis)
            try container.encodeIfPresent(latencyMilliseconds, forKey: .latencyMilliseconds)
            try container.encodeIfPresent(peakMemoryBytes, forKey: .peakMemoryBytes)
            try container.encodeIfPresent(reason, forKey: .reason)
            let records = tokens?.map { token in
                TokenRecord(text: token.text, start: token.start, duration: token.duration,
                            confidence: token.confidence, alternatives: token.alternatives)
            }
            try container.encodeIfPresent(records, forKey: .tokens)
        }
    }

    /// 一个系统（引擎 × locale × 解码方式）跑完整份清单的结果。
    public struct SystemRun: Sendable, Equatable, Codable {
        /// 与 `TranscriptionHypothesis.engineID` 同一命名空间（如 `qwen3`、`classic:zh-CN`、`classic:en-US`）。
        public var engineID: String
        public var results: [UtteranceResult]
        /// 整个系统被跳过的原因（未授权、该 locale 不支持端侧……）；非 nil 时不参与任何比较。
        public var skipReason: String?
        /// 运行配置备注（如 contextualStrings 条数），原样进报告。
        public var notes: String?

        public init(engineID: String, results: [UtteranceResult], skipReason: String? = nil, notes: String? = nil) {
            self.engineID = engineID
            self.results = results
            self.skipReason = skipReason
            self.notes = notes
        }

        public static func skipped(_ engineID: String, reason: String, notes: String? = nil) -> SystemRun {
            SystemRun(engineID: engineID, results: [], skipReason: reason, notes: notes)
        }
    }
}
