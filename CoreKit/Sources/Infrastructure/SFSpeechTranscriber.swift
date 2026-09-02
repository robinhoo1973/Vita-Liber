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

    public init() {
        self.capability = .baseline()   // 基线轨：不支持长音频、单段 ≤60s
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

        let audio = AVAudioEngine()
        let recog = SFSpeechAudioBufferRecognitionRequest()
        recog.requiresOnDeviceRecognition = true
        recog.shouldReportPartialResults = true
        recog.taskHint = .dictation
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
