// 平台守卫镜像 Package.swift 的平台条件（ERR#8 纪律）：AVFoundation 仅 Apple 平台可用。
#if os(iOS) || os(macOS)
// linux-blind: AVFoundation 音频 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import AVFoundation
import Domain
import Protocols

/// FR17.13 / FR17.16 的生产 TTS 实现。
///
/// 只做两件事：按回退链解析发声 locale（规则来自 Protocols 的 `SpeechFallback`，
/// 本类不自定义规则），然后交给 `AVSpeechSynthesizer` 播报。
/// 语速取 FR14.7「默认语速」偏好，未设时用系统默认。
public final class AVSpeechAdapter: NSObject, SpeechSynthesizing,
                                    AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let rateProvider: @Sendable () -> Float?
    private let stopLock = NSLock()
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init(rateProvider: @escaping @Sendable () -> Float? = { nil }) {
        self.rateProvider = rateProvider
        super.init()
        synthesizer.delegate = self
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

    /// 先登记等待者再停止：`stopSpeaking` 可能同步触发 didCancel，若先停后
    /// 登记，delegate 早已回调、等待者永远挂住。空闲时停止不会触发 delegate，
    /// 由 stop 返回后的 `isSpeaking` 检查兜底 flush。
    public func stopAndWait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stopLock.lock()
            stopWaiters.append(continuation)
            stopLock.unlock()
            synthesizer.stopSpeaking(at: .immediate)
            if !synthesizer.isSpeaking { finishStopWaiters() }
        }
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    // MARK: - AVSpeechSynthesizerDelegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                  didFinish utterance: AVSpeechUtterance) {
        finishStopWaiters()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                  didCancel utterance: AVSpeechUtterance) {
        finishStopWaiters()
    }

    /// 幂等：delegate 与 isSpeaking 兜底可能同时到达，只放行一次。
    private func finishStopWaiters() {
        stopLock.lock()
        let waiters = stopWaiters
        stopWaiters.removeAll()
        stopLock.unlock()
        for waiter in waiters { waiter.resume() }
    }
}
#endif
