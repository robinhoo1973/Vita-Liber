#if os(iOS) || os(macOS)
// linux-blind: Speech 框架仅 Apple 切片；macOS CI 编译、真机运行。
import Foundation
import Speech
import Domain
import Protocols

/// Apple 第二/第三源的系统适配器：把 `SFSpeechRecognizer` 的授权/端侧能力折叠成
/// Domain 纯值，并把文件识别结果映射为 `ASRAppleSourceResult`。
///
/// 强制端侧：实际识别委托 `AppleSpeechFileTranscriber`（`requiresOnDeviceRecognition = true`）；
/// 本适配器不提供任何联网识别分支，也不保留音频（调用方传入的临时文件由调用方删除）。
public struct AppleSpeechSourceAdapter: ASRAppleSourceRunning {
    public init() {}

    public func availability() async -> ASRAppleSourceAvailabilityFacts {
        Self.availabilityFacts()
    }

    public static func availabilityFacts() -> ASRAppleSourceAvailabilityFacts {
        var available = Set<String>()
        var onDevice = Set<String>()
        for source in ASRAppleSourceCatalog.sources {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: source.localeIdentifier)) else {
                continue
            }
            if recognizer.isAvailable { available.insert(source.localeIdentifier) }
            if recognizer.supportsOnDeviceRecognition { onDevice.insert(source.localeIdentifier) }
        }
        return ASRAppleSourceAvailabilityFacts(
            authorization: map(SFSpeechRecognizer.authorizationStatus()),
            recognizerAvailableLocales: available,
            onDeviceCapableLocales: onDevice)
    }

    public func requestAuthorization() async -> ASRAppleAuthorization {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return Self.map(status) }
        let granted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        return granted ? .authorized : Self.map(SFSpeechRecognizer.authorizationStatus())
    }

    public func transcribe(audioURL: URL, source: ASRAppleSource,
                           contextualStrings: [String]) async -> ASRAppleSourceResult {
        let hypothesis = await AppleSpeechFileTranscriber.transcribe(
            audioURL: audioURL, locale: source.localeIdentifier,
            contextualStrings: contextualStrings, role: .secondary)
        switch hypothesis.status {
        case .recognized:
            return ASRAppleSourceResult(
                source: source, status: .recognized, elapsedMs: hypothesis.elapsedMs,
                hypothesis: hypothesis.transcriptionHypothesis)
        case .failed, .skipped:
            return ASRAppleSourceResult(
                source: source, status: hypothesis.status, reason: hypothesis.reason,
                elapsedMs: hypothesis.elapsedMs,
                hypothesis: hypothesis.transcriptionHypothesis)
        }
    }

    static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> ASRAppleAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .restricted
        }
    }
}
#endif
