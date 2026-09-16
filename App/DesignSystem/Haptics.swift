import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// tech-spec §5.15 触觉反馈单出口（业主 2026-09-16 第 5 项「同时增加震动反馈」）。
///
/// 为什么走 UIKit 生成器而不是 iOS 17 的 `.sensoryFeedback`：部署目标是 16.0
/// （swift-perception 回移植），`.sensoryFeedback` 需要 `#available(iOS 17, *)`
/// 分支且**必须挂在视图上**——录音的起止发生在模型层（`VoiceDictationModel`
/// 的 start/stop 是多个入口共用的唯一收口：按住说话、无障碍动作、语音面板、
/// 引导表单都走它），挂在某个视图上必然漏掉别的入口。`UIImpactFeedbackGenerator`
/// 是 iOS 13+ 的成熟实现（成熟实现优先），在模型层就能发。
///
/// 分级（spec §5.15 语义分级）：起止 = impact（开 medium / 停 light），
/// 失败 = notice(.warning)（不阻断手输路径），成功交付 = notice(.success)。
/// 系统「触感」关闭时 UIKit 生成器自动静默，本层不再判开关；呼叫方均在
/// `@MainActor` 上下文（UIKit 要求主线程）。
@MainActor
enum Haptics {
    enum Impact: Sendable { case light, medium, heavy }
    enum Notice: Sendable { case success, warning, error }

    /// 轻/中/重冲击（状态切换）：`prepare()` 预热以压低首次触发的延迟。
    static func impact(_ style: Impact = .medium) {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: style.uiStyle)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    /// 结果通知（成功/警告/错误）
    static func notice(_ kind: Notice) {
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(kind.uiType)
        #endif
    }
}

#if canImport(UIKit)
private extension Haptics.Impact {
    var uiStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: return .light
        case .medium: return .medium
        case .heavy: return .heavy
        }
    }
}

private extension Haptics.Notice {
    var uiType: UINotificationFeedbackGenerator.FeedbackType {
        switch self {
        case .success: return .success
        case .warning: return .warning
        case .error: return .error
        }
    }
}
#endif
