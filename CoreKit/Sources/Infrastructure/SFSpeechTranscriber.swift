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
public actor SFSpeechTranscriber: TranscriptionEngine {
    public nonisolated let capability: TranscriptionCapability
    private var activeTask: SFSpeechRecognitionTask?

    public init() {
        self.capability = .baseline()   // 基线轨：不支持长音频、单段 ≤60s
    }

    public func transcribe(_ request: TranscriptionRequest,
                          onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
        guard SFSpeechRecognizer.supportsOnDeviceRecognition else {
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
        let resolvedLocale = capability.availableLocales.contains(request.localeIdentifier)
            ? request.localeIdentifier : TranscriptionSegmentation.fallbackLocale
        recog.locale = Locale(identifier: resolvedLocale)
        // 注：基线轨 SFSpeechAudioBufferRecognitionRequest 不支持 contextualStrings；
        // 药名密集场景建议升级轨（见 ADR-023）。

        let inputNode = audio.inputNode
        let fmt = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [recog] buffer, _ in
            recog.append(buffer)
        }
        audio.prepare()
        try audio.start()

        let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TranscriptionResult, Error>) in
            var settled = false
            let task = SFSpeechRecognizer().recognitionTask(with: recog) { ts, err in
                if let err {
                    if !settled { settled = true; cont.resume(throwing: err) }
                    return
                }
                guard let ts else { return }
                if ts.isFinal {
                    let text = ts.bestTranscription.formattedString
                    let conf = ts.transcriptions.map(\.confidence).reduce(0, +)
                        / Double(max(ts.transcriptions.count, 1))
                    let segmented = Double(request.expectedDurationSeconds ?? 0)
                        > Double(self.capability.maxSegmentSeconds)
                    if !settled {
                        settled = true
                        cont.resume(returning: TranscriptionResult(
                            text: text, confidence: conf,
                            resolvedLocale: resolvedLocale, segmented: segmented))
                    }
                } else {
                    onPartial?(ts.bestTranscription.formattedString)
                }
            }
            Task { await self.setActiveTask(task) }
        }

        audio.stop()
        inputNode.removeTap(onBus: 0)
        await self.clearActiveTask()
        return result
    }

    private func setActiveTask(_ t: SFSpeechRecognitionTask) { activeTask = t }
    private func clearActiveTask() { activeTask?.cancel(); activeTask = nil }
}
#endif
