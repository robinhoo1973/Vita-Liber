import Foundation
import Domain

/// FR17.9/FR17.18 端侧文本润色端口（tech §5.13 `TextRefining` / `LocalTranscriptRefiner`）：
/// 输入原生转写，输出 `TranscriptRevision`——**永不覆盖原文**，建议经 `ProtectedTokenValidator`
/// 校验后才 `.accepted`；不可用/超时/校验失败一律回原文，保存与 FR17.13 确认路径不被阻塞。
/// 端侧、零网络（EAL `onDeviceOnly`）；紧急关键词在润色前判定（BR-012）、措辞负清单在展示前过滤（BR-006）。
public protocol TextRefining: Sendable {
    /// 本机是否可用（Foundation Models 可用性 + 平台门控；不含用户授权——授权由 App 层 authAI 门控）
    var isAvailable: Bool { get async }
    /// 润色；`drugNames` 供受保护 token 校验（用户已确认药名）
    func refine(_ original: String, localeIdentifier: String, drugNames: [String]) async -> TranscriptRevision
}

/// 不可用替身（iOS < 26 / 非 Apple 平台 / 模型未就绪）：诚实返回 `.unavailable`，效果 = 原文。
public struct UnavailableTextRefiner: TextRefining {
    public init() {}
    public var isAvailable: Bool { get async { false } }
    public func refine(_ original: String, localeIdentifier: String, drugNames: [String]) async -> TranscriptRevision {
        .unavailable(original)
    }
}
