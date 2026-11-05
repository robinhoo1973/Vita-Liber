import Foundation
import Domain
import Protocols

/// 主轨实时识别 + **采集结束后** Apple 中文/英文文件识别的生产编排。
///
/// 业主 2026-11-05 修正：没有三源实时并行要求。主轨在按压期间照常采音并出实时文本；
/// 松手后主轨先收尾，若存在录音缓冲，再把同一段音频交给 Apple zh-CN / en-US
/// 做文件识别（两者可在采集结束后并行），结果只作为第二/第三文本假设附在
/// `TranscriptionResult.hypotheses`，**交付文本仍由主轨决定**（当前融合默认 reviewOnly）。
///
/// 音频边界：
/// - 调用方已提供录音 URL（聊天语音消息）→ 直接复用，识别后**不删除**（聊天负责 adopt）；
/// - 调用方未提供 → 在系统临时目录创建受保护的私有临时文件，Apple 识别结束立即删除；
/// - 绝不写入识别调试目录，绝不保留音频副本。
///
/// 生命周期：`finish/cancel/discardSession/endAudio` 全部转发主轨；Apple 副源只读主轨
/// 已写出的录音，不持有麦克风，因此不会与主轨争采音。
public actor AppleSecondaryTranscriptionEngine: TranscriptionEngine,
                                                TranscriptionCaptureReporting,
                                                TranscriptionAudioRecording {
    private nonisolated let primary: any TranscriptionEngine
    private nonisolated let apples: any ASRAppleSourceRunning
    /// 调用方在本次按压前设置的目标；nil = 调用方不录音，由本类型临时承接。
    private var recordingURL: URL?

    public init(primary: any TranscriptionEngine, apples: any ASRAppleSourceRunning) {
        self.primary = primary
        self.apples = apples
        _ = Self.purgeOnce
    }

    public nonisolated var capability: TranscriptionCapability { primary.capability }

    public func currentCapability() async -> TranscriptionCapability {
        await primary.currentCapability()
    }

    public func setRecordingURL(_ url: URL?) async {
        recordingURL = url
        if let recorder = primary as? any TranscriptionAudioRecording {
            await recorder.setRecordingURL(url)
        }
    }

    public func transcribe(_ request: TranscriptionRequest,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
        try await transcribe(request, onPartial: onPartial, onCaptureStarted: {})
    }

    public func transcribe(_ request: TranscriptionRequest, onPartial: (@Sendable (String) -> Void)?,
                           onCaptureStarted: @escaping @Sendable () -> Void) async throws -> TranscriptionResult {
        let callerURL = recordingURL
        let ownURL = callerURL == nil ? Self.makeTemporaryAudioURL() : nil
        let audioURL = callerURL ?? ownURL
        defer {
            // 只删自己创建的临时文件；调用方的录音归调用方（聊天消息/显式留存）。
            if let ownURL { try? FileManager.default.removeItem(at: ownURL) }   // try?-ok: 临时音频清理尽力而为
        }
        // 主轨按本次按压的目标写出录音；nil 也要转发，防止沿用上一会话的旧目标。
        if let recorder = primary as? any TranscriptionAudioRecording {
            await recorder.setRecordingURL(audioURL)
        }

        let result: TranscriptionResult
        if let reporting = primary as? any TranscriptionCaptureReporting {
            result = try await reporting.transcribe(request, onPartial: onPartial,
                                                    onCaptureStarted: onCaptureStarted)
        } else {
            onCaptureStarted()
            result = try await primary.transcribe(request, onPartial: onPartial)
        }

        // 主轨结果先原样保留；Apple 副源只是附加证据，失败/超时/取消都不影响交付。
        guard let audioURL,
              FileManager.default.fileExists(atPath: audioURL.path) else { return result }
        return await attachAppleHypotheses(to: result, request: request, audioURL: audioURL)
    }

    public func finish(sessionID: UUID) async { await primary.finish(sessionID: sessionID) }
    public func cancel(sessionID: UUID) async { await primary.cancel(sessionID: sessionID) }
    public func discardSession(sessionID: UUID) async { await primary.discardSession(sessionID: sessionID) }
    public func endAudio() async { await primary.endAudio() }

    public func localeAssetStatus(_ localeIdentifier: String) async -> VoiceLocaleAssetStatus {
        await primary.localeAssetStatus(localeIdentifier)
    }

    public func prepareLocale(_ localeIdentifier: String) async -> Bool {
        await primary.prepareLocale(localeIdentifier)
    }

    public func warmUp(_ localeIdentifier: String) async -> Bool {
        await primary.warmUp(localeIdentifier)
    }

    /// 采集结束后的 Apple 副源：先按授权/端侧/locale/同源重复做纯策略计划，
    /// 再把可用源并行送文件识别。主轨文本、置信度、completion 均不改写。
    private func attachAppleHypotheses(to result: TranscriptionResult,
                                       request: TranscriptionRequest,
                                       audioURL: URL) async -> TranscriptionResult {
        var plan = await apples.plan(primaryEngineID: result.engineID,
                                     primaryLocale: result.resolvedLocale)
        if plan.requiresAuthorizationPrompt {
            _ = await apples.requestAuthorization()
            plan = await apples.plan(primaryEngineID: result.engineID,
                                     primaryLocale: result.resolvedLocale)
        }
        let existing = Set(result.hypotheses.map(\.engineID))
        let sources = plan.runs.filter { !existing.contains($0.engineID) }
        guard !sources.isEmpty, !Task.isCancelled else { return result }

        let appleRunner = apples
        let contextualStrings = request.contextualStrings
        let outcomes = await withTaskGroup(of: ASRAppleSourceResult.self) { group in
            for source in sources {
                group.addTask {
                    await appleRunner.transcribe(audioURL: audioURL, source: source,
                                                contextualStrings: contextualStrings)
                }
            }
            var values: [ASRAppleSourceResult] = []
            for await outcome in group { values.append(outcome) }
            return values
        }
        guard !Task.isCancelled else { return result }

        var enriched = result
        for outcome in outcomes.sorted(by: { $0.source.role.ordinal < $1.source.role.ordinal }) {
            guard outcome.sourceHypothesis.isUsable,
                  let hypothesis = outcome.hypothesis,
                  !enriched.hypotheses.contains(where: { $0.engineID == hypothesis.engineID }) else {
                continue
            }
            enriched.hypotheses.append(hypothesis)
        }
        return enriched
    }

    private static let temporaryFolderName = "ASRSecondaryAudio"

    /// 进程内**只执行一次**（Swift lazy static）：清理上次崩溃/强退遗留的临时音频。
    /// 不能在每次 `init` 都删目录——同进程内多个引擎实例（测试/多窗口）会互删正在
    /// 识别的临时文件，实测触发 “The file doesn’t exist”。
    private static let purgeOnce: Void = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(temporaryFolderName, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)   // try?-ok: 启动清理尽力而为
    }()

    private static func makeTemporaryAudioURL() -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(temporaryFolderName, isDirectory: true)
        do {
            var attributes: [FileAttributeKey: Any] = [:]
            #if os(iOS) || os(macOS)
            attributes[.protectionKey] = FileProtectionType.complete
            #endif
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: attributes.isEmpty ? nil : attributes)
            return directory.appendingPathComponent("capture-\(UUID().uuidString).caf")
        } catch {
            return nil
        }
    }
}
