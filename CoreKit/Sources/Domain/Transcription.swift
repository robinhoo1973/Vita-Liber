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
}

public struct TranscriptionRequest: Sendable, Equatable {
    public var localeIdentifier: String
    /// 药名等领域词提示（升级轨 contextualStrings 路由，提升密集药名识别率）
    public var contextualStrings: [String]
    /// 预计时长（秒）——用于分段规划；未知传 nil
    public var expectedDurationSeconds: Int?
    public init(localeIdentifier: String, contextualStrings: [String] = [],
                expectedDurationSeconds: Int? = nil) {
        self.localeIdentifier = localeIdentifier
        self.contextualStrings = contextualStrings
        self.expectedDurationSeconds = expectedDurationSeconds
    }
}

public struct TranscriptionResult: Sendable, Equatable {
    public var text: String
    public var confidence: Double
    /// 实际使用的 locale（方言不可用时回落普通话，FR17.15「尽力识别」）
    public var resolvedLocale: String
    /// 是否走了分段续接（基线轨长录音）
    public var segmented: Bool
    public init(text: String, confidence: Double, resolvedLocale: String, segmented: Bool) {
        self.text = text; self.confidence = confidence
        self.resolvedLocale = resolvedLocale; self.segmented = segmented
    }
}

/// 转写不可用时的降级（FR17.6：不可用即手输，不是崩溃）
public enum TranscriptionError: Error, Sendable, Equatable {
    case unauthorized          // 未授权「语音速记识别」（F14.1）
    case engineUnavailable     // 设备端引擎缺失
    case noSpeechDetected
}
