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
/// - 识别器必须被**强持有**到识别结束（Apple 文档要求），原临时量一释放识别即中断；
/// - 置信度位于 `bestTranscription.segments[].confidence`（SFTranscription 无 confidence）；
/// - 清理（audio.stop/removeTap/task.cancel）在错误路径同样必须执行（原实现只在成功
///   路径清理——抛错后 AVAudioEngine 持续采音、task 悬挂）。
public actor SFSpeechTranscriber: TranscriptionEngine {
    public nonisolated let capability: TranscriptionCapability
    /// 当前识别任务与识别器（识别期间强持有，结束后清空）
    private var activeTask: SFSpeechRecognitionTask?
    private var activeRecognizer: SFSpeechRecognizer?

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

        activeRecognizer = recognizer    // 强持有至识别结束
        let maxSeg = capability.maxSegmentSeconds

        // 错误/正常路径统一走 do/catch 清理（audio/移除 tap/清任务——评审修正）
        do {
            let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TranscriptionResult, Error>) in
                var settled = false
                let task = recognizer.recognitionTask(with: recog) { [weak self] ts, err in
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
                Task { await self?.hold(task) }
            }
            audio.stop()
            inputNode.removeTap(onBus: 0)
            await release()
            return result
        } catch {
            audio.stop()
            inputNode.removeTap(onBus: 0)
            await release()
            throw error
        }
    }

    /// 记录进行中的任务（识别期间保持引用，供取消/清理）
    private func hold(_ t: SFSpeechRecognitionTask) {
        activeTask?.cancel()
        activeTask = t
    }

    private func release() {
        activeTask?.cancel()
        activeTask = nil
        activeRecognizer = nil
    }
}
#endif
