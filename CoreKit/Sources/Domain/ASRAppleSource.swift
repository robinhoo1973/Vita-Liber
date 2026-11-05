import Foundation

/// Apple 第二/第三识别源的固定身份（业主裁决 2026-11-04）。
///
/// Apple 识别器**按 locale 实例化**：中文、英文各一个 `SFSpeechRecognizer`。
/// 两者都强制端侧（`requiresOnDeviceRecognition = true`），**绝不回落联网识别**；
/// 结果只作为文本假设进入融合，不保存音频/图片。
public enum ASRAppleSourceRole: String, Sendable, Equatable, Codable {
    /// 第二模型：Apple 中文。
    case secondAppleChinese
    /// 第三模型：Apple 英文。
    case thirdAppleEnglish

    /// 在「主轨 + 第二 + 第三」中的位置（主轨 = 1）。
    public var ordinal: Int {
        switch self {
        case .secondAppleChinese: return 2
        case .thirdAppleEnglish: return 3
        }
    }

    public var hypothesisRole: RecognitionDebugCapture.Hypothesis.Role { .secondary }
}

public struct ASRAppleSource: Sendable, Equatable {
    public let role: ASRAppleSourceRole
    public let localeIdentifier: String

    public init(role: ASRAppleSourceRole, localeIdentifier: String) {
        self.role = role
        self.localeIdentifier = localeIdentifier
    }

    /// 与 `AppleSpeechFileTranscriber.engineID(locale:)` 同一命名空间。
    public var engineID: String { ASRAppleSourceCatalog.engineID(for: localeIdentifier) }
    public var sourceGroup: String { ASRAppleSourceCatalog.sourceGroup }
    /// 类型级事实：端侧识别是唯一允许的路径。
    public var requiresOnDeviceRecognition: Bool { true }
    /// 类型级事实：不允许联网回落（离线优先红线）。
    public var allowsNetworkFallback: Bool { false }
}

public enum ASRAppleSourceCatalog {
    public static let sourceGroup = "apple-speech"
    public static let chineseLocale = "zh-CN"
    public static let englishLocale = "en-US"

    public static let secondSource = ASRAppleSource(role: .secondAppleChinese,
                                                    localeIdentifier: chineseLocale)
    public static let thirdSource = ASRAppleSource(role: .thirdAppleEnglish,
                                                   localeIdentifier: englishLocale)
    /// 固定顺序：第二 = 中文，第三 = 英文。
    public static let sources: [ASRAppleSource] = [secondSource, thirdSource]

    public static func engineID(for locale: String) -> String { "apple-\(locale)" }

    public static func source(for role: ASRAppleSourceRole) -> ASRAppleSource {
        switch role {
        case .secondAppleChinese: return secondSource
        case .thirdAppleEnglish: return thirdSource
        }
    }
}

/// 系统侧授权状态（Domain 不知道 `SFSpeechRecognizer` 类型，只接收映射后的纯值）。
public enum ASRAppleAuthorization: String, Sendable, Equatable, Codable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

/// 单个 Apple locale 的系统能力事实（由 Infrastructure 探针填入）。
public struct ASRAppleSourceAvailabilityFacts: Sendable, Equatable {
    public var authorization: ASRAppleAuthorization
    /// `SFSpeechRecognizer(locale:) != nil && recognizer.isAvailable` 的 locale 集。
    public var recognizerAvailableLocales: Set<String>
    /// `recognizer.supportsOnDeviceRecognition == true` 的 locale 集。
    public var onDeviceCapableLocales: Set<String>

    public init(authorization: ASRAppleAuthorization,
                recognizerAvailableLocales: Set<String> = [],
                onDeviceCapableLocales: Set<String> = []) {
        self.authorization = authorization
        self.recognizerAvailableLocales = recognizerAvailableLocales
        self.onDeviceCapableLocales = onDeviceCapableLocales
    }
}

public enum ASRAppleSourceUnavailability: String, Sendable, Equatable, Codable {
    case authorizationNotDetermined
    case authorizationDenied
    case authorizationRestricted
    /// `SFSpeechRecognizer(locale:)` 无该 locale。
    case localeUnsupported
    /// 该 locale 不支持端侧识别——**不得**退回联网识别。
    case onDeviceUnsupported
    case recognizerUnavailable
    /// 主轨本身就是同语种 Apple 基线轨：同源重复，不当作独立投票。
    case duplicateOfPrimaryClassic
}

public enum ASRAppleSourceReadiness: Sendable, Equatable {
    case ready
    /// 授权未决定：必须先显式请求一次授权，再重新评估；不会静默降级。
    case requiresAuthorizationPrompt
    case unavailable(ASRAppleSourceUnavailability)
}

public struct ASRAppleSourceSkip: Sendable, Equatable {
    public var source: ASRAppleSource
    public var reason: ASRAppleSourceUnavailability

    public init(source: ASRAppleSource, reason: ASRAppleSourceUnavailability) {
        self.source = source
        self.reason = reason
    }
}

/// 一次按压的 Apple 副源执行计划（纯策略）。
public struct ASRAppleSourcePlan: Sendable, Equatable {
    public var runs: [ASRAppleSource]
    public var skipped: [ASRAppleSourceSkip]
    /// true = 先请求一次语音识别授权；授权结果回来前不启动任何 Apple 识别。
    public var requiresAuthorizationPrompt: Bool

    public init(runs: [ASRAppleSource], skipped: [ASRAppleSourceSkip],
                requiresAuthorizationPrompt: Bool) {
        self.runs = runs
        self.skipped = skipped
        self.requiresAuthorizationPrompt = requiresAuthorizationPrompt
    }
}

/// Apple 第二/第三源的可用性策略：只判断「能否以端侧方式启动」，不承诺语言质量。
public enum ASRAppleSourcePolicy {
    public static func readiness(of source: ASRAppleSource,
                                 facts: ASRAppleSourceAvailabilityFacts) -> ASRAppleSourceReadiness {
        switch facts.authorization {
        case .notDetermined: return .requiresAuthorizationPrompt
        case .denied: return .unavailable(.authorizationDenied)
        case .restricted: return .unavailable(.authorizationRestricted)
        case .authorized: break
        }
        let locale = source.localeIdentifier
        guard facts.recognizerAvailableLocales.contains(locale) else {
            return .unavailable(.localeUnsupported)
        }
        guard facts.onDeviceCapableLocales.contains(locale) else {
            return .unavailable(.onDeviceUnsupported)
        }
        return .ready
    }

    /// 生成执行计划。`primaryEngineID` / `primaryLocale` 用于识别「主轨已是同语种
    /// Apple 基线轨」的同源重复（与调试采集 `duplicate-of-production-classic` 同口径）。
    public static func plan(primaryEngineID: String?,
                            primaryLocale: String?,
                            facts: ASRAppleSourceAvailabilityFacts,
                            sources: [ASRAppleSource] = ASRAppleSourceCatalog.sources) -> ASRAppleSourcePlan {
        var runs: [ASRAppleSource] = []
        var skipped: [ASRAppleSourceSkip] = []
        var needsPrompt = false
        for source in sources {
            if isDuplicateOfPrimaryClassic(source, primaryEngineID: primaryEngineID,
                                           primaryLocale: primaryLocale) {
                skipped.append(.init(source: source, reason: .duplicateOfPrimaryClassic))
                continue
            }
            switch readiness(of: source, facts: facts) {
            case .ready:
                runs.append(source)
            case .requiresAuthorizationPrompt:
                needsPrompt = true
                skipped.append(.init(source: source, reason: .authorizationNotDetermined))
            case .unavailable(let reason):
                skipped.append(.init(source: source, reason: reason))
            }
        }
        return ASRAppleSourcePlan(runs: runs, skipped: skipped,
                                  requiresAuthorizationPrompt: needsPrompt)
    }

    /// 主轨引擎 ID 去掉 `:locale` 后缀后若为 `classic`（Apple 基线轨），且语种前缀相同，
    /// 则该 Apple 副源是同一识别栈的同源重复。
    public static func isDuplicateOfPrimaryClassic(_ source: ASRAppleSource,
                                                   primaryEngineID: String?,
                                                   primaryLocale: String?) -> Bool {
        guard let primaryEngineID else { return false }
        let base = primaryEngineID.split(separator: ":").first.map(String.init) ?? primaryEngineID
        if base == source.engineID { return true }
        guard base == VoiceEngineChoice.classic.rawValue else { return false }
        let primaryLanguage = (primaryLocale ?? "").prefix(2).lowercased()
        let sourceLanguage = source.localeIdentifier.prefix(2).lowercased()
        return !primaryLanguage.isEmpty && primaryLanguage == sourceLanguage
    }
}
