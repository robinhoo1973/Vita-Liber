import Foundation
import Domain

/// F17 语音转写端口（tech-spec §5.13 / ADR-023 双轨门控）。
///
/// **音频零落盘是类型级保证，不是测试级期望**：本协议的入参与出参里
/// 没有任何 `URL` / `Data` / 文件句柄（值对象定义见 Domain/Transcription.swift）——
/// 音频缓冲只存在于实现内部的流式管线中，调用方拿不到、也交不出音频字节。
/// FR17.7「音频缓冲即用即弃不落盘」因此在编译期就无处违反；
/// TC-M15-02 的沙盒 diff 断言是第二道防线而非唯一防线。
///
/// **双轨门控（ADR-023）**：iOS 26 起的升级轨支持长音频不分段；基线轨
/// （SFSpeechRecognizer）有 ~60s 截断限制，必须分段续接。两轨经同一协议暴露，
/// 上层零感知——分段策略由 `TranscriptionSegmentation` 依 `capability` 决定。
public protocol TranscriptionEngine: Sendable {
    /// Capability snapshot; currentCapability() refreshes runtime availability when supported.
    var capability: TranscriptionCapability { get }
    func currentCapability() async -> TranscriptionCapability
    /// 开始一次转写。实现内部自行采集音频；`onPartial` 回传实时文本用于边说边显示。
    func transcribe(_ request: TranscriptionRequest,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult
    /// Stop this press's hardware before returning, then drain its recognition with a bounded timeout.
    /// Must also work before authorization/setup completes. IDs are single-use.
    func finish(sessionID: UUID) async
    /// Stop hardware, cancel native work, and settle this press exactly once without delivering text.
    func cancel(sessionID: UUID) async
    /// Retire an abandoned request after cancellation, including one that never registered.
    func discardSession(sessionID: UUID) async
    /// Legacy unscoped stop. New callers must use finish(sessionID:).
    func endAudio() async
}

extension TranscriptionEngine {
    public func currentCapability() async -> TranscriptionCapability { capability }
    /// Existing text-only stubs have no hardware; production engines must override both scoped methods.
    public func finish(sessionID: UUID) async { await endAudio() }
    public func cancel(sessionID: UUID) async { await finish(sessionID: sessionID) }
    public func discardSession(sessionID: UUID) async {}
    public func endAudio() async {}
}

/// 测试与 Preview 用桩：两轨可用性各构造一份，验证「同一协议下行为一致」
/// （TC-M15-04 双轨门控用例）。同样不接触任何文件。
public actor StubTranscriptionEngine: TranscriptionEngine {
    public nonisolated let capability: TranscriptionCapability
    private let scripted: [String]
    private var cursor = 0

    public init(capability: TranscriptionCapability, scripted: [String]) {
        self.capability = capability
        self.scripted = scripted
    }

    public func transcribe(_ request: TranscriptionRequest,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        guard !scripted.isEmpty else { throw TranscriptionError.noSpeechDetected }
        guard let locale = capability.resolvedLocale(for: request.localeIdentifier) else {
            throw TranscriptionError.engineUnavailable
        }
        let text = scripted[min(cursor, scripted.count - 1)]
        cursor += 1
        onPartial?(text)
        let plan = TranscriptionSegmentation.plan(
            durationSeconds: request.expectedDurationSeconds ?? 0,
            capability: capability)
        return TranscriptionResult(text: text, confidence: 0.92,
                                   resolvedLocale: locale,
                                   segmented: plan.count > 1)
    }
}
