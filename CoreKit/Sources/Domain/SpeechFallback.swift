import Foundation

/// 发声语言回退链（FR17.16）+ 发声结果值对象。结构轮 2026-09-15：自
/// Protocols/SpeechSynthesizing.swift 迁入——回退链是一条业务规则（FR17.16
/// 「必须只有一个实现点」），按 tech-spec §1.1 规则 4 归属 Domain 纯函数；
/// Protocols 只保留抽象与契约桩（P3）。两端实现（AVSpeechAdapter /
/// SherpaOnnxSpeechSynthesizer）经 Domain 消费，零接口变化。
public struct SpeechOutcome: Sendable, Equatable {
    /// 实际发声使用的 locale（可能因回退而不同于请求值）
    public var spokenLocale: String
    /// 是否发生了回退——UI 据此显示「当前用普通话朗读」轻提示（FR17.16）
    public var didFallback: Bool
    public init(spokenLocale: String, didFallback: Bool) {
        self.spokenLocale = spokenLocale; self.didFallback = didFallback
    }
}

/// 发声语言回退链（FR17.16），纯函数——两端实现共用，避免第二套规则。
public enum SpeechFallback {
    /// - Parameter availableVoices: 平台探测到的可发声 locale 集合。
    /// 审查修复：回退目标必须真实可用——原实现直接返回 fallbackLocale 而不
    /// 校验其存在（语音包被清理时 utterance.voice = nil，系统默认音朗读中文
    /// 成乱码，而 outcome 仍虚报「普通话已回退」）。回退语音也不可用时
    /// 如实报告实际使用的语音。
    /// 审查修复（确定性）：Set 迭代顺序随进程哈希种子随机——`availableVoices.first`
    /// 会把「任选一个中文语音」变成每次启动随机一种腔（zh-CN/zh-TW/zh-HK
    /// 轮换），同一句话今天普通话、明天台湾腔（outcome 虽如实但发声语言
    /// 漂移）。按字典序取首个（zh-* 中 zh-CN/zh-Hans 天然靠前），逐次确定。
    public static func resolve(requested: String,
                               availableVoices: Set<String>) -> SpeechOutcome {
        if availableVoices.contains(requested) {
            return SpeechOutcome(spokenLocale: requested, didFallback: false)
        }
        let fallback = TranscriptionSegmentation.fallbackLocale
        if availableVoices.contains(fallback) {
            return SpeechOutcome(spokenLocale: fallback, didFallback: true)
        }
        let sorted = availableVoices.sorted()
        let anyChinese = sorted.first { $0.hasPrefix("zh") }
        let actual = anyChinese ?? sorted.first ?? fallback
        return SpeechOutcome(spokenLocale: actual, didFallback: true)
    }
}
