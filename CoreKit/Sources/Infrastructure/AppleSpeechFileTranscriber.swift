#if os(iOS) || os(macOS)
// linux-blind: Speech 框架仅 Apple 切片；文件识别只在 macOS CI 编译、真机运行。
import Foundation
import Speech
import Domain

/// Apple 语音识别的**文件**入口（2026-11-04 真机调试采集）。
///
/// 业主裁决：ASR 主轨按硬件/设置选出（多为下载的混说模型），Apple 中文、Apple 英文
/// 固定作第二、第三模型参与对照。生产按压只跑主轨（麦克风独占），调试开关开启后
/// 把同一段录音文件交给本类型各跑一遍。只用 `SFSpeechURLRecognitionRequest`：
/// - **强制离线**（`requiresOnDeviceRecognition`）：系统不支持该语言离线识别时
///   返回 `.skipped`，绝不回落到联网识别（离线优先红线）；
/// - 与生产基线轨同一证据装配（`TranscriptionTokenAssembly.platformTokens`），
///   保证对照口径一致。
public enum AppleSpeechFileTranscriber {
    /// 单次文件识别上限（防系统回调丢失时调试任务永久挂起）。
    public static let timeoutSeconds: Double = 90

    public static func engineID(locale: String) -> String { "apple-\(locale)" }

    /// 识别一个音频文件；任何失败都折叠进返回值（调试采集尽力而为，不抛错）。
    public static func transcribe(audioURL: URL, locale: String, contextualStrings: [String],
                                  role: RecognitionDebugCapture.Hypothesis.Role = .secondary)
        async -> RecognitionDebugCapture.Hypothesis {
        let engineID = engineID(locale: locale)
        func outcome(_ status: RecognitionDebugCapture.Hypothesis.Status, _ reason: String,
                     elapsed: Double? = nil) -> RecognitionDebugCapture.Hypothesis {
            RecognitionDebugCapture.Hypothesis(engineID: engineID, sourceGroup: "apple-speech", role: role,
                                               status: status, reason: reason, locale: locale,
                                               elapsedMs: elapsed, text: "")
        }
        guard await authorize() else { return outcome(.skipped, "speech-not-authorized") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            return outcome(.skipped, "locale-unsupported")
        }
        guard recognizer.supportsOnDeviceRecognition else { return outcome(.skipped, "on-device-unsupported") }
        guard recognizer.isAvailable else { return outcome(.skipped, "recognizer-unavailable") }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.contextualStrings = Array(contextualStrings.prefix(MixedSpeechVocabulary.limit))

        let started = Date()
        let box = ResultBox()
        let result: Result<TranscriptionHypothesis, FailureReason> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.install(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        box.resume(.success(hypothesis(from: result, engineID: engineID, locale: locale)))
                    } else if let error {
                        let nsError = error as NSError
                        box.resume(.failure(FailureReason(text: "\(nsError.domain):\(nsError.code)")))
                    }
                }
                box.attach(task)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                    box.resume(.failure(FailureReason(text: "timeout")))
                }
            }
        } onCancel: {
            box.resume(.failure(FailureReason(text: "cancelled")))
        }
        let elapsed = Date().timeIntervalSince(started) * 1000
        switch result {
        case .failure(let reason):
            return outcome(.failed, reason.text, elapsed: elapsed)
        case .success(let hypothesis):
            return RecognitionDebugCapture.Hypothesis(hypothesis, sourceGroup: "apple-speech", role: role,
                                                      elapsedMs: elapsed)
        }
    }

    /// 与生产基线轨同一证据装配（段时间/置信度/替代写法 + 请求级 n-best）。
    private static func hypothesis(from result: SFSpeechRecognitionResult, engineID: String,
                                   locale: String) -> TranscriptionHypothesis {
        let best = result.bestTranscription
        let segments = best.segments.map {
            TranscriptionTokenAssembly.PlatformSegment(text: $0.substring, start: $0.timestamp,
                                                       duration: $0.duration,
                                                       confidence: Double($0.confidence),
                                                       alternatives: $0.alternativeSubstrings)
        }
        let tokens = TranscriptionTokenAssembly.platformTokens(segments)
        return TranscriptionHypothesis(
            engineID: engineID, localeIdentifier: locale, text: best.formattedString,
            tokens: tokens,
            // 置信度种类按实际装配结果判定：段全无置信度时 `platformTokens` 会清空逐词置信度，
            // 此时仍写 `.engineNative` 会让下游把「无置信度」误当原生置信度。
            confidenceKind: TranscriptionTokenAssembly.confidenceKind(of: tokens),
            alternativeTexts: TranscriptionTokenAssembly.alternativeTexts(
                best: best.formattedString, candidates: result.transcriptions.map(\.formattedString)))
    }

    private static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    private struct FailureReason: Error, Sendable {
        var text: String
    }

    /// 一次性续体：系统回调、超时、取消三路竞争，只放行第一个。
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<TranscriptionHypothesis, FailureReason>, Never>?
        private var pending: Result<TranscriptionHypothesis, FailureReason>?
        private var task: SFSpeechRecognitionTask?

        func install(_ continuation: CheckedContinuation<Result<TranscriptionHypothesis, FailureReason>, Never>) {
            lock.lock()
            if let pending {
                lock.unlock()
                continuation.resume(returning: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func attach(_ task: SFSpeechRecognitionTask) {
            lock.lock()
            let finished = continuation == nil && pending != nil
            self.task = task
            lock.unlock()
            if finished { task.cancel() }
        }

        func resume(_ result: Result<TranscriptionHypothesis, FailureReason>) {
            lock.lock()
            guard pending == nil else { lock.unlock(); return }
            pending = result
            let continuation = self.continuation
            self.continuation = nil
            let task = self.task
            lock.unlock()
            continuation?.resume(returning: result)
            if case .failure = result { task?.cancel() }
        }
    }
}
#endif
