import Foundation

/// F17 转写值对象（tech-spec §5.13 / ADR-023）。
///
/// **为什么在 Domain 而不是 Protocols**：这些是纯值对象（能力描述/请求/结果），
/// 而 Domain 的分段规则 `TranscriptionSegmentation` 要依赖 `TranscriptionCapability`。
/// 依赖方向是 Protocols → Domain（tech-spec §1.1），把值对象放 Protocols 会让
/// Domain 反向依赖 Protocols，破坏分层。端口 `TranscriptionEngine` 仍在 Protocols。
///
/// **音频零落盘的类型级保证**：这三个类型里没有任何 `URL`/`Data`/文件句柄——
/// 音频缓冲只存在于引擎实现内部的流式管线里，调用方拿不到也交不出音频字节，
/// FR17.7 因此在编译期就无处违反。

/// 引擎能力（ADR-023 双轨门控的两态由 `supportsLongForm` 承载）
public struct TranscriptionCapability: Sendable, Equatable {
    /// 升级轨=true（长音频免分段）；基线轨=false（SFSpeechRecognizer ~60s 截断）
    public var supportsLongForm: Bool
    /// 基线轨单段上限秒数
    public var maxSegmentSeconds: Int
    /// 该引擎实际可用的 locale 标识集（FR17.15 六语种矩阵的探测结果）
    public var availableLocales: Set<String>
    public init(supportsLongForm: Bool, maxSegmentSeconds: Int, availableLocales: Set<String>) {
        self.supportsLongForm = supportsLongForm
        self.maxSegmentSeconds = maxSegmentSeconds
        self.availableLocales = availableLocales
    }

    /// 基线轨（SFSpeechRecognizer）默认能力
    public static func baseline(locales: Set<String> = ["zh-Hans-CN"]) -> TranscriptionCapability {
        TranscriptionCapability(supportsLongForm: false, maxSegmentSeconds: 60, availableLocales: locales)
    }
    /// 升级轨（iOS 26+）默认能力
    public static func longForm(locales: Set<String> = ["zh-Hans-CN"]) -> TranscriptionCapability {
        TranscriptionCapability(supportsLongForm: true, maxSegmentSeconds: .max, availableLocales: locales)
    }

    /// Return the probed identifier, not a synthesized spelling of a locale.
    public func locale(matching identifier: String) -> String? {
        if availableLocales.contains(identifier) { return identifier }
        let normalized = TranscriptionLocale.normalizedIdentifier(identifier)
        return availableLocales.sorted().first {
            TranscriptionLocale.normalizedIdentifier($0) == normalized
        }
    }

    public func resolvedLocale(for identifier: String) -> String? {
        if let exact = locale(matching: identifier) { return exact }
        switch TranscriptionLocale.normalizedIdentifier(identifier) {
        case "yue-hant-hk", "yue-hans-cn", "nan-tw", "wuu-cn", "zh-hans-cn-sichuan":
            return locale(matching: "zh-Hans-CN")
        default:
            return nil
        }
    }
}

public enum TranscriptionLocale {
    /// Known Speech/BCP-47 aliases only; unrelated regions and unknown dialects stay distinct.
    public static func normalizedIdentifier(_ identifier: String) -> String {
        let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-").lowercased()
        switch key {
        case "zh-cn", "zh-hans-cn": return "zh-hans-cn"
        case "zh-hk", "zh-hant-hk", "yue-hk", "yue-hant-hk": return "yue-hant-hk"
        case "yue-cn", "yue-hans-cn": return "yue-hans-cn"
        case "zh-tw", "zh-hant-tw": return "zh-hant-tw"
        default: return key
        }
    }
}

public struct TranscriptionRequest: Sendable, Equatable {
    /// Single-use press identity. Allocate before scheduling transcription so early stop is addressable.
    public let sessionID: UUID
    public var localeIdentifier: String
    /// 药名等领域词提示（升级轨 contextualStrings 路由，提升密集药名识别率）
    public var contextualStrings: [String]
    /// 预计时长（秒）——用于分段规划；未知传 nil
    public var expectedDurationSeconds: Int?
    public init(localeIdentifier: String, contextualStrings: [String] = [],
                expectedDurationSeconds: Int? = nil, sessionID: UUID = UUID()) {
        self.sessionID = sessionID
        self.localeIdentifier = localeIdentifier
        self.contextualStrings = contextualStrings
        self.expectedDurationSeconds = expectedDurationSeconds
    }
}

/// A recovered partial is still unconfirmed text, never a successful native final.
public enum TranscriptionCompletion: String, Sendable, Equatable {
    case final, partial, timedOut, interrupted, bufferOverflow
}

public struct TranscriptionResult: Sendable, Equatable {
    public var text: String
    public var confidence: Double
    /// 实际使用的 locale（方言不可用时回落普通话，FR17.15「尽力识别」）
    public var resolvedLocale: String
    /// 是否走了分段续接（基线轨长录音）
    public var segmented: Bool
    /// V3.61：会话内各识别段（停顿/60s 换段产生；单段时为空或单元素，向后兼容）
    public var segments: [String]
    public var completion: TranscriptionCompletion
    public init(text: String, confidence: Double, resolvedLocale: String, segmented: Bool,
                segments: [String] = [], completion: TranscriptionCompletion = .final) {
        self.text = text; self.confidence = confidence
        self.resolvedLocale = resolvedLocale; self.segmented = segmented
        self.segments = segments
        self.completion = completion
    }
}

/// 转写不可用时的降级（FR17.6：不可用即手输，不是崩溃）
public enum TranscriptionError: Error, Sendable, Equatable {
    case unauthorized          // 未授权「语音速记识别」（F14.1）
    case engineUnavailable     // 设备端引擎缺失
    case noSpeechDetected
    case timedOut
    case audioBufferOverflow
}
