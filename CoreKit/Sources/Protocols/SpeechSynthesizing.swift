import Foundation
import Domain

/// TTS 端口（FR17.13 回读 / FR17.16 输出语言 / FR19.3 播报）。
///
/// 协议化的两个理由（tech-spec §1.1 规则 3）：
/// ① CI 无法断言「扬声器发出了声音」，但可以断言「回读了哪段文本、用了哪个 locale」——
///    测试替身把不可观测的副作用变成可断言的记录；
/// ② FR17.16 的发声回退链（指定方言 → 无独立发声 → 普通话朗读 + 轻提示）
///    是一条业务规则，必须只有一个实现点，不能散落在各视图。
public protocol SpeechSynthesizing: Sendable {
    /// 播报一段**已确认的结构化文本**。实现负责发声回退并回报实际发声 locale。
    @discardableResult
    func speak(_ text: String, localeIdentifier: String) -> SpeechOutcome
    func stop()
}

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
    public static func resolve(requested: String,
                               availableVoices: Set<String>) -> SpeechOutcome {
        if availableVoices.contains(requested) {
            return SpeechOutcome(spokenLocale: requested, didFallback: false)
        }
        let fallback = TranscriptionSegmentation.fallbackLocale
        if availableVoices.contains(fallback) {
            return SpeechOutcome(spokenLocale: fallback, didFallback: true)
        }
        let anyChinese = availableVoices.first { $0.hasPrefix("zh") }
        let actual = anyChinese ?? availableVoices.first ?? fallback
        return SpeechOutcome(spokenLocale: actual, didFallback: true)
    }
}

/// 测试/Preview 替身：把播报记录下来供断言，不发声、不触碰任何系统服务。
public final class RecordingSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    public struct Utterance: Sendable, Equatable {
        public var text: String
        public var requestedLocale: String
        public var outcome: SpeechOutcome
    }
    private let lock = NSLock()
    private var _spoken: [Utterance] = []
    private let availableVoices: Set<String>

    public init(availableVoices: Set<String> = [TranscriptionSegmentation.fallbackLocale]) {
        self.availableVoices = availableVoices
    }

    public var spoken: [Utterance] {
        lock.lock(); defer { lock.unlock() }
        return _spoken
    }

    @discardableResult
    public func speak(_ text: String, localeIdentifier: String) -> SpeechOutcome {
        let outcome = SpeechFallback.resolve(requested: localeIdentifier,
                                             availableVoices: availableVoices)
        lock.lock()
        _spoken.append(Utterance(text: text, requestedLocale: localeIdentifier, outcome: outcome))
        lock.unlock()
        return outcome
    }

    public func stop() {}
}
