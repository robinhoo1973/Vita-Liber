import Foundation

/// 启动时是否预热 ASR 主轨（纯策略；2026-11-05 业主目标「启动时按硬件预载 ASR 模型」）。
///
/// 只做**选择**，不加载模型：App 启动链在后台调用 `warmUp`，本策略回答
/// 「现在是否值得预载、预载哪个档位」。约束：
/// - 只允许预热 advisor 已判定可加载（`budgetIsTight == false`）的已安装主轨；
/// - 热状态未知按不安全处理（预热可选，未知不冒险）；
/// - 低电量未知同样按不安全处理；
/// - 不联网、不触发下载、不采音——这些由调用方与 `warmUp` 端口保证。
public enum ASRStartupPreloadSkipReason: String, Sendable, Equatable, Codable {
    /// 混说模式：warmUp 端口只接受单一 locale，启动期无法保证选中与
    /// advisor 一致的多语种主轨；留给按压路径按 request 解析。
    case mixedLanguageMode
    /// 没有通过硬件/安装/目录过滤的主轨（由按压路径回落平台/基线轨）。
    case noPrimaryModel
    /// 内存余量紧：不在启动时抢占，留给用户按压时的显式加载。
    case memoryBudgetTight
    /// 热状态 serious/critical。
    case thermalConstrained
    /// 热状态探针不可用：未知按不安全处理。
    case thermalUnknown
    /// 低电量模式开启。
    case lowPowerMode
    /// 低电量模式未知：未知按不安全处理。
    case lowPowerModeUnknown
}

public enum ASRStartupPreloadDecision: Sendable, Equatable {
    case preload(choice: VoiceEngineChoice, locale: String)
    case skip(ASRStartupPreloadSkipReason)
}

public enum ASRStartupPreloadPolicy {
    /// 输入必须是同一时刻的 advisor 结果与硬件事实；纯函数、确定性、无 IO。
    public static func decide(advice: ASRModelAdvice,
                              hardware: ASRHardwareFacts) -> ASRStartupPreloadDecision {
        guard advice.languageMode == .single else { return .skip(.mixedLanguageMode) }
        guard let primary = advice.primary else { return .skip(.noPrimaryModel) }
        guard !primary.budgetIsTight else { return .skip(.memoryBudgetTight) }
        switch hardware.thermal {
        case .nominal, .fair:
            break
        case .serious, .critical:
            return .skip(.thermalConstrained)
        case .unknown:
            return .skip(.thermalUnknown)
        }
        switch hardware.lowPowerMode {
        case .some(false):
            break
        case .some(true):
            return .skip(.lowPowerMode)
        case .none:
            return .skip(.lowPowerModeUnknown)
        }
        return .preload(choice: primary.choice, locale: advice.locale)
    }
}
