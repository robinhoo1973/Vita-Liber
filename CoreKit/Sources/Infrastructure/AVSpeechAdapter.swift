// 平台守卫镜像 Package.swift 的平台条件（ERR#8 纪律）：AVFoundation 仅 Apple 平台可用。
#if os(iOS) || os(macOS)
import Foundation
import AVFoundation
import Domain
import Protocols

/// FR17.13 / FR17.16 的生产 TTS 实现。
///
/// 只做两件事：按回退链解析发声 locale（规则来自 Protocols 的 `SpeechFallback`，
/// 本类不自定义规则），然后交给 `AVSpeechSynthesizer` 播报。
/// 语速取 FR14.7「默认语速」偏好，未设时用系统默认。
public final class AVSpeechAdapter: SpeechSynthesizing, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let rateProvider: @Sendable () -> Float?

    public init(rateProvider: @escaping @Sendable () -> Float? = { nil }) {
        self.rateProvider = rateProvider
    }

    /// 平台可发声 locale 集合（探测一次，`AVSpeechSynthesisVoice.speechVoices()`
    /// 随系统语音包安装变化，故每次读取而不缓存——缓存会让用户新装语音包后仍被判不可用）。
    private var availableVoices: Set<String> {
        Set(AVSpeechSynthesisVoice.speechVoices().map(\.language))
    }

    @discardableResult
    public func speak(_ text: String, localeIdentifier: String) -> SpeechOutcome {
        let outcome = SpeechFallback.resolve(requested: localeIdentifier,
                                             availableVoices: availableVoices)
        let utterance = AVSpeechUtterance(string: text)
        // 审查修复：解析结果保证可用（SpeechFallback 已校验），
        // 极端情况下 voice 仍为 nil 时按系统默认如实发声（不再虚报 locale）
        utterance.voice = AVSpeechSynthesisVoice(language: outcome.spokenLocale)
        if let rate = rateProvider() { utterance.rate = rate }
        synthesizer.speak(utterance)
        return outcome
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
#endif
