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
    /// 停止播报并等到本合成器不再发声。默认实现轮询 `isSpeaking`
    /// （无完成回调的替身）；AV 实现用 delegate 完成回调，避免
    /// `stopSpeaking(at:.immediate)` 返回后音频尾音仍被麦克风采入。
    func stopAndWait() async
    /// 是否仍有在途播报；默认 false（无完成回调的替身），AV 实现如实返回。
    var isSpeaking: Bool { get }
}

public extension SpeechSynthesizing {
    var isSpeaking: Bool { false }

    func stopAndWait() async {
        stop()
        for _ in 0..<20 where isSpeaking {
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
        }
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
