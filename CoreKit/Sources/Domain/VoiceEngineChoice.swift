import Foundation

/// FR17.15 V3.66：语音识别引擎档位（用户可选；设置键 `voiceEngine`，模型实验室与生产共用同一值）。
///
/// - `auto`：系统智能选择——iOS 26+ 且平台升级轨可用时用 `SpeechTranscriber`，否则回落经典基线轨。
/// - `advanced`：强制平台自由对话轨（SpeechAnalyzer + SpeechTranscriber，iOS 26+）。
/// - `dictation`：强制系统听写同源轨（SpeechAnalyzer + DictationTranscriber，iOS 26+）。
/// - `classic`：强制 SFSpeechRecognizer 基线轨（零资产、全 iOS 17+ 可用）。
///
/// 纯值对象，零框架依赖；档位可用性由引擎层运行时探测（Domain 不做平台判断）。
public enum VoiceEngineChoice: String, Sendable, CaseIterable, Codable {
    case auto
    case qwen3
    case dolphin
    case zipformer
    case whisper
    case advanced
    case dictation
    case classic

    /// 设置持久化值 → 档位；非法/缺省回落 `auto`（与 AppSettingKey 默认值同源）。
    public static func resolve(_ raw: String?) -> VoiceEngineChoice {
        guard let raw, let value = VoiceEngineChoice(rawValue: raw) else { return .auto }
        return value
    }

    /// 该档位是否属于平台分析器家族（iOS 26+ 门控；UI 据此标注「需要 iOS 26」）。
    public var usesPlatformAnalyzer: Bool {
        switch self {
        case .advanced, .dictation: return true
        case .auto, .classic, .qwen3, .zipformer, .dolphin, .whisper: return false
        }
    }

    /// 需要下载语言资源包的档位（平台分析器家族按 locale 安装；基线轨零资产）。
    public var requiresLocaleAssets: Bool { self == .advanced || self == .dictation }

    public var isBundledModel: Bool { self == .qwen3 || self == .zipformer || self == .dolphin || self == .whisper }
}

/// FR17.15 V3.66：识别引擎档位在当前设备/系统上的可用性（Infrastructure 层运行时探测，App 只呈现）。
public enum VoiceEngineAvailability: Sendable, Equatable {
    /// 可用（auto 恒可用；平台轨经 isAvailable + 系统版本探测）。
    case available
    /// 需要更新的系统版本（iOS 26 起）。
    case requiresNewerOS
    /// 设备不支持（硬件/模型能力不足）。
    case unsupportedDevice
    /// 随包模型缺失或清单不匹配，不能将占位桩显示为可用引擎。
    case missingModelAssets
}

/// FR17.15 V3.66：某 locale 的端侧识别资源状态（平台升级轨按需下载；基线轨零资产恒 `.installed`）。
public enum VoiceLocaleAssetStatus: String, Sendable, Equatable, Codable {
    /// 已安装，可直接识别。
    case installed
    /// 系统支持、可按需下载（下载后离线可用）。
    case downloadable
    /// 该引擎不支持此 locale。
    case unavailable
}
