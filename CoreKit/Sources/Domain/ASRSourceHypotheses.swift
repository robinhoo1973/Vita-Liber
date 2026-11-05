import Foundation

/// 三源合同中的角色：主轨 + Apple 中文 + Apple 英文。
public enum ASRSourceRole: String, Sendable, Hashable, Codable {
    case primary
    case secondAppleChinese
    case thirdAppleEnglish

    public var ordinal: Int {
        switch self {
        case .primary: return 1
        case .secondAppleChinese: return 2
        case .thirdAppleEnglish: return 3
        }
    }

    public var hypothesisRole: RecognitionDebugCapture.Hypothesis.Role {
        self == .primary ? .primary : .secondary
    }

    public init(_ role: ASRAppleSourceRole) {
        switch role {
        case .secondAppleChinese: self = .secondAppleChinese
        case .thirdAppleEnglish: self = .thirdAppleEnglish
        }
    }

    public var appleRole: ASRAppleSourceRole? {
        switch self {
        case .primary: return nil
        case .secondAppleChinese: return .secondAppleChinese
        case .thirdAppleEnglish: return .thirdAppleEnglish
        }
    }
}

/// 一个源对一次按压的文本假设（**只含文本与原生词元证据**）。
///
/// 本类型没有 `URL` / `Data` / 文件句柄字段：三源对照不会持久化音频或图片，
/// 调试采集也只经 `RecognitionDebugCapture` 写文本 JSON。
public struct ASRSourceHypothesis: Sendable, Equatable {
    public var role: ASRSourceRole
    public var engineID: String
    public var sourceGroup: String
    public var status: RecognitionDebugCapture.Hypothesis.Status
    /// 未运行/失败原因（诊断字符串，不交付、不参与融合投票）。
    public var reason: String?
    public var hypothesis: TranscriptionHypothesis?
    public var elapsedMs: Double?

    public init(role: ASRSourceRole, engineID: String, sourceGroup: String,
                status: RecognitionDebugCapture.Hypothesis.Status, reason: String? = nil,
                hypothesis: TranscriptionHypothesis? = nil, elapsedMs: Double? = nil) {
        self.role = role
        self.engineID = engineID
        self.sourceGroup = sourceGroup
        self.status = status
        self.reason = reason
        self.hypothesis = hypothesis
        self.elapsedMs = elapsedMs
    }

    public static func recognized(role: ASRSourceRole, hypothesis: TranscriptionHypothesis,
                                  sourceGroup: String, elapsedMs: Double? = nil) -> Self {
        .init(role: role, engineID: hypothesis.engineID, sourceGroup: sourceGroup,
              status: .recognized, hypothesis: hypothesis, elapsedMs: elapsedMs)
    }

    public static func skipped(role: ASRSourceRole, engineID: String, sourceGroup: String,
                               reason: String, locale: String? = nil) -> Self {
        var hypothesis: TranscriptionHypothesis?
        if let locale {
            hypothesis = TranscriptionHypothesis(engineID: engineID, localeIdentifier: locale, text: "")
        }
        return .init(role: role, engineID: engineID, sourceGroup: sourceGroup,
                     status: .skipped, reason: reason, hypothesis: hypothesis)
    }

    public static func failed(role: ASRSourceRole, engineID: String, sourceGroup: String,
                              reason: String, locale: String? = nil, elapsedMs: Double? = nil) -> Self {
        var hypothesis: TranscriptionHypothesis?
        if let locale {
            hypothesis = TranscriptionHypothesis(engineID: engineID, localeIdentifier: locale, text: "")
        }
        return .init(role: role, engineID: engineID, sourceGroup: sourceGroup,
                     status: .failed, reason: reason, hypothesis: hypothesis, elapsedMs: elapsedMs)
    }

    /// 只有「识别成功且非空文本」的源参与融合投票；skipped/failed 只保留在调试证据里。
    public var isUsable: Bool {
        guard status == .recognized, let hypothesis else { return false }
        return !hypothesis.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var text: String { hypothesis?.text ?? "" }
    public var localeIdentifier: String? { hypothesis?.localeIdentifier }

    /// 转为调试采集的假设（文本 JSON，无媒体）。
    public var debugHypothesis: RecognitionDebugCapture.Hypothesis {
        guard let hypothesis else {
            return RecognitionDebugCapture.Hypothesis(
                engineID: engineID, sourceGroup: sourceGroup, role: role.hypothesisRole,
                status: status, reason: reason, locale: nil, elapsedMs: elapsedMs, text: "")
        }
        var value = RecognitionDebugCapture.Hypothesis(
            hypothesis, sourceGroup: sourceGroup, role: role.hypothesisRole, elapsedMs: elapsedMs)
        value.status = status
        value.reason = reason
        return value
    }
}

/// Apple 文件/缓冲识别的结果（适配器输出；纯 Domain 值）。
public struct ASRAppleSourceResult: Sendable, Equatable {
    public var source: ASRAppleSource
    public var status: RecognitionDebugCapture.Hypothesis.Status
    public var reason: String?
    public var elapsedMs: Double?
    public var hypothesis: TranscriptionHypothesis?

    public init(source: ASRAppleSource, status: RecognitionDebugCapture.Hypothesis.Status,
                reason: String? = nil, elapsedMs: Double? = nil,
                hypothesis: TranscriptionHypothesis? = nil) {
        self.source = source
        self.status = status
        self.reason = reason
        self.elapsedMs = elapsedMs
        self.hypothesis = hypothesis
    }

    public static func skipped(_ source: ASRAppleSource,
                               reason: ASRAppleSourceUnavailability) -> Self {
        .init(source: source, status: .skipped, reason: reason.rawValue)
    }

    public static func skipped(_ source: ASRAppleSource, reason: String) -> Self {
        .init(source: source, status: .skipped, reason: reason)
    }

    public static func failed(_ source: ASRAppleSource, reason: String,
                              elapsedMs: Double? = nil) -> Self {
        .init(source: source, status: .failed, reason: reason, elapsedMs: elapsedMs)
    }

    public var sourceHypothesis: ASRSourceHypothesis {
        .init(role: ASRSourceRole(source.role), engineID: source.engineID,
              sourceGroup: source.sourceGroup, status: status, reason: reason,
              hypothesis: hypothesis, elapsedMs: elapsedMs)
    }
}

/// 三源假设集合：固定包含主轨、Apple 中文、Apple 英文三个角色；跳过/失败也占位，
/// 保证「三源都有记录、但只有可用源参与融合」。
public struct ASRThreeSourceHypotheses: Sendable, Equatable {
    public var sources: [ASRSourceHypothesis]

    public init(sources: [ASRSourceHypothesis]) {
        self.sources = sources
    }

    /// 编译期合同：三个角色各一条，角色不重复。缺角色时返回 nil（调用方补 skipped 占位）。
    public var isComplete: Bool {
        let roles = Set(sources.map(\.role))
        return roles == Set([.primary, .secondAppleChinese, .thirdAppleEnglish])
    }

    public func source(for role: ASRSourceRole) -> ASRSourceHypothesis? {
        sources.first { $0.role == role }
    }

    public var primary: ASRSourceHypothesis? { source(for: .primary) }
    public var usableSecondaries: [ASRSourceHypothesis] {
        sources.filter { $0.role != .primary && $0.isUsable }
    }

    /// 融合输入：主轨 + 可用副源（按角色固定顺序：Apple 中文 → Apple 英文）。
    /// 主轨不可用 → nil（不替用户挑副轨，交付语义不变）。
    public func fusionInput() -> ASRFusionInput? {
        guard let primary = primary, primary.isUsable, let hypothesis = primary.hypothesis else {
            return nil
        }
        let secondaries = usableSecondaries
            .sorted { $0.role.ordinal < $1.role.ordinal }
            .compactMap(\.hypothesis)
        return ASRFusionInput(primary: hypothesis, secondaries: secondaries)
    }

    /// 只提示融合（默认 `reviewOnly`，交付文本仍是主轨原文）。
    public func fuse(calibration: HypothesisFusionCalibration,
                     options: HypothesisFusionOptions = HypothesisFusionOptions()) -> FusedTranscript? {
        fusionInput()?.fuse(calibration: calibration, options: options)
    }

    /// 调试采集段：三条假设（含 skipped/failed 原因），**只有文本**。
    public func debugSegment(index: Int = 0) -> RecognitionDebugCapture.Segment {
        RecognitionDebugCapture.Segment(
            index: index,
            hypotheses: sources.sorted { $0.role.ordinal < $1.role.ordinal }.map(\.debugHypothesis))
    }

    /// 文本证据行（可直接编码为 JSON；无音频/图片/路径字段）。
    public func textEvidence() -> [ASRTextEvidenceLine] {
        sources.sorted { $0.role.ordinal < $1.role.ordinal }.map {
            ASRTextEvidenceLine(
                role: $0.role.rawValue, engineID: $0.engineID, sourceGroup: $0.sourceGroup,
                status: $0.status.rawValue, reason: $0.reason,
                locale: $0.localeIdentifier, text: $0.text,
                confidence: $0.hypothesis.flatMap(Self.meanConfidence),
                confidenceKind: $0.hypothesis?.confidenceKind.rawValue
                    ?? TranscriptionConfidenceKind.unavailable.rawValue)
        }
    }

    private static func meanConfidence(_ hypothesis: TranscriptionHypothesis) -> Double? {
        let values = hypothesis.tokens.compactMap(\.confidence)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// 由生产主轨结果 + Apple 副源结果装配三源集合；缺失的 Apple 角色补 `not-run` 占位
    /// （角色合同始终完整，融合只取可用源）。
    public static func assemble(primary result: TranscriptionResult, primarySourceGroup: String,
                                apples: [ASRAppleSourceResult]) -> ASRThreeSourceHypotheses {
        let primaryHypothesis: TranscriptionHypothesis
        if let matched = result.hypotheses.first(where: { $0.engineID == result.engineID }) {
            primaryHypothesis = matched
        } else {
            primaryHypothesis = TranscriptionHypothesis(
                engineID: result.engineID ?? "primary",
                localeIdentifier: result.resolvedLocale, text: result.text)
        }
        var sources: [ASRSourceHypothesis] = [
            .recognized(role: .primary, hypothesis: primaryHypothesis, sourceGroup: primarySourceGroup)
        ]
        for role in [ASRAppleSourceRole.secondAppleChinese, .thirdAppleEnglish] {
            let source = ASRAppleSourceCatalog.source(for: role)
            if let match = apples.first(where: { $0.source.role == role }) {
                sources.append(match.sourceHypothesis)
            } else {
                sources.append(.skipped(role: ASRSourceRole(role), engineID: source.engineID,
                                        sourceGroup: source.sourceGroup, reason: "not-run",
                                        locale: source.localeIdentifier))
            }
        }
        return ASRThreeSourceHypotheses(sources: sources)
    }
}

/// 融合内核的纯文本输入（主轨 + 副源）。不含音频/图片/路径。
public struct ASRFusionInput: Sendable, Equatable {
    public var primary: TranscriptionHypothesis
    public var secondaries: [TranscriptionHypothesis]

    public init(primary: TranscriptionHypothesis, secondaries: [TranscriptionHypothesis]) {
        self.primary = primary
        self.secondaries = secondaries
    }

    public func fuse(calibration: HypothesisFusionCalibration,
                     options: HypothesisFusionOptions = HypothesisFusionOptions()) -> FusedTranscript {
        HypothesisFusion.fuse(primary: primary, secondaries: secondaries,
                              calibration: calibration, options: options)
    }
}

/// 一行文本证据（调试回传用）。字段白名单式设计：没有任何媒体/路径字段。
public struct ASRTextEvidenceLine: Sendable, Equatable, Codable {
    public var role: String
    public var engineID: String
    public var sourceGroup: String
    public var status: String
    public var reason: String?
    public var locale: String?
    public var text: String
    public var confidence: Double?
    public var confidenceKind: String

    public init(role: String, engineID: String, sourceGroup: String, status: String,
                reason: String? = nil, locale: String? = nil, text: String,
                confidence: Double? = nil, confidenceKind: String) {
        self.role = role
        self.engineID = engineID
        self.sourceGroup = sourceGroup
        self.status = status
        self.reason = reason
        self.locale = locale
        self.text = text
        self.confidence = confidence
        self.confidenceKind = confidenceKind
    }
}
