#if os(iOS) || os(macOS)
import Foundation
import AVFoundation
import Speech
import Domain
import Protocols

/// ADR-023 基线轨：端侧 SFSpeechRecognizer（`requiresOnDeviceRecognition=true`，隐私红线 BR-002 延伸）。
///
/// 升级轨（iOS 26+）的 `SpeechAnalyzer`/`SpeechTranscriber`（长音频免分段）在同 `TranscriptionEngine`
/// 协议下替换本类——上层零感知降级。医学词表注入（contextualStrings）在基线轨受限，
/// 密集药名录音建议走升级轨（DictationTranscriber 路径，见 ADR-023）。
///
/// 评审修正（Apple SDK 首次真实编译暴露，5WHY 同 CaptureQuality——Apple 轨代码此前
/// 无任何编译门禁）：
/// - `SFSpeechRecognizer(locale:)` 是 failable init，locale 在这里注入（request 无 locale
///   属性）；`supportsOnDeviceRecognition` 是**实例**属性而非类属性；
/// - 识别器必须被**强持有**到识别结束（Apple 文档要求）。本实现中 recognizer/recog/audio
///   均为 transcribe 局部量，被识别任务回调闭包捕获——task 存活期间识别器必存活，
///   函数返回（isFinal/error）后随闭包释放，天然满足强持有语义；
/// - 置信度位于 `bestTranscription.segments[].confidence`（SFTranscription 无 confidence）；
/// - 清理（audio.stop/removeTap）在错误与成功路径统一执行（do/catch + 路径内清理），
///   修复原实现抛错后 AVAudioEngine 持续采音泄漏。
///
/// 注：早期版本曾用 actor 属性持有 activeTask/activeRecognizer 以便外部取消——Swift 6
/// 下 handler 回调对 actor self 是 isolated 强捕获（[weak self] 不生效，编译报
/// "optional chaining on non-optional"），属性管理反而制造编译障碍且与局部捕获
/// 语义重复，故移除；外部取消/超时属后续能力（登记待办）。
public actor SFSpeechTranscriber: TranscriptionEngine {
    public nonisolated let capability: TranscriptionCapability

    /// 活跃会话计数：软停（VoiceDictationModel.stop）不取消引擎——旧会话
    /// 仍等静音端点、其 defer 才复位音频会话。快速重录时新旧两个 transcribe
    /// 并发，旧会话先结束若无条件 setActive(false) 会把新会话已激活的共享
    /// 会话一并关掉，新录音静默收不到缓冲。计数归零才复位。
    private var activeSessions = 0
    /// 当前活跃识别请求（软停 endAudio 尽快终结旧会话；仅最新会话）
    private var activeRecognition: SFSpeechAudioBufferRecognitionRequest?

    public init() {
        // FR17.15 六语种能力**运行时探测**（tech §5.13「不硬编码」）：
        // supportedLocales ∩ 端侧识别——此前 .baseline() 恒 {zh-Hans-CN}，
        // 选择粤语/英语后全部回落普通话识别（注释声称「用户选择的输入语言
        // 必须生效」与实现矛盾，假能力呈现）
        self.capability = Self.probeCapability()
    }

    /// 探测实际可用的端侧识别 locale 集；探测失败回落 zh-Hans-CN（绝不
    /// 声称支持未探测的语种）
    private static func probeCapability() -> TranscriptionCapability {
        let probed = SFSpeechRecognizer.supportedLocales().filter { locale in
            SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
        }.map(\.identifier)
        let locales = probed.isEmpty ? ["zh-Hans-CN"] : probed
        return .baseline(locales: Set(locales))
    }

    /// 软停提示：endAudio 让旧会话尽快出 isFinal 收尾（协议默认无操作）
    public func endAudio() {
        activeRecognition?.endAudio()
    }

    public func transcribe(_ request: TranscriptionRequest,
                          onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
        let resolvedLocale = capability.availableLocales.contains(request.localeIdentifier)
            ? request.localeIdentifier : TranscriptionSegmentation.fallbackLocale
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: resolvedLocale)) else {
            throw TranscriptionError.engineUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.engineUnavailable
        }
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard auth == .authorized else { throw TranscriptionError.unauthorized }

        let recog = SFSpeechAudioBufferRecognitionRequest()
        recog.requiresOnDeviceRecognition = true
        recog.shouldReportPartialResults = true
        recog.taskHint = .dictation

        let audio = AVAudioEngine()
        // 审查修复：AVAudioSession 必须显式配置为录音类别并激活——
        // 默认 soloAmbient 无录音输入，inputNode.installTap 后 audio.start()
        // 在真机上收不到任何 buffer（FR17.16 语音速记生产不可用）。
        // AVAudioSession 仅 iOS 可用（CI 34018308312 实证：macOS 编译报
        // 'unavailable in macOS'）——macOS 无音频会话概念，AVAudioEngine
        // 无需 session 配置即可工作，故整块 #if os(iOS) 限定。
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            throw TranscriptionError.engineUnavailable
        }
        activeSessions += 1
        activeRecognition = recog
        defer {
            activeSessions -= 1
            // 仅当无其他活跃转写会话时复位共享音频会话——软停后的旧会话
            // 不得关掉新会话已激活的录音输入
            if activeSessions == 0 {
                try? session.setActive(false, options: [.notifyOthersOnDeactivation])   // try?-ok: 会话复位失败不掩盖主结果
            }
            // 仅清空自己的识别请求引用（新会话可能已覆盖）
            if activeRecognition === recog { activeRecognition = nil }
        }
        #endif
        // 注：基线轨 request 无 contextualStrings（药名词表注入受限），见 ADR-023。

        let inputNode = audio.inputNode
        let fmt = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [recog] buffer, _ in
            recog.append(buffer)
        }
        audio.prepare()
        try audio.start()

        let maxSeg = capability.maxSegmentSeconds

        // recognizer/audio/recog 均被回调闭包强捕获：识别期间不被释放（Apple 要求）。
        // 错误与成功路径都执行清理，绝不让采音引擎悬挂（评审修正）。
        let result: TranscriptionResult
        do {
            result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TranscriptionResult, Error>) in
                var settled = false
                _ = recognizer.recognitionTask(with: recog) { ts, err in
                    if let err {
                        if !settled { settled = true; cont.resume(throwing: err) }
                        return
                    }
                    guard let ts else { return }
                    if ts.isFinal {
                        if !settled {
                            settled = true
                            let text = ts.bestTranscription.formattedString
                            let segs = ts.bestTranscription.segments
                            let conf = segs.map(\.confidence).reduce(0, +) / Float(max(segs.count, 1))
                            let segmented = Double(request.expectedDurationSeconds ?? 0) > Double(maxSeg)
                            cont.resume(returning: TranscriptionResult(
                                text: text, confidence: Double(conf),
                                resolvedLocale: resolvedLocale, segmented: segmented))
                        }
                    } else {
                        onPartial?(ts.bestTranscription.formattedString)
                    }
                }
            }
        } catch {
            audio.stop()
            inputNode.removeTap(onBus: 0)
            throw error
        }
        audio.stop()
        inputNode.removeTap(onBus: 0)
        return result
    }
}
#endif
