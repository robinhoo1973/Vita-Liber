import Foundation
import Domain
import Protocols
#if os(iOS)
import UIKit
#endif

/// ADR-023：随包开源权重的生产端口。初始化不加载模型，能力查询不启动麦克风。
public final class SherpaOnnxTranscriber: TranscriptionCaptureReporting, @unchecked Sendable {
    private let choice: VoiceEngineChoice
    private let assets: ASRModelAssets
    private let assetLease: ASRModelAssets.Lease
    private var memoryObserver: NSObjectProtocol?
    #if canImport(SherpaOnnxC)
    private let coordinator: SpeechSessionCoordinator<SherpaSpeechSessionDriver>
    #endif

    public init(choice: VoiceEngineChoice = .zipformer, assets: ASRModelAssets? = nil) {
        self.choice = choice
        // 缺省即走双路径解析（下载版优先、随包回落）——后续新增调用点不再可能
        // 忘调 resolve 而静默忽略已装下载模型（EngineFactories 四处的显式 resolve 保留）。
        let resolvedAssets = assets ?? ASRModelAssets.resolve(for: choice)
        self.assets = resolvedAssets
        self.assetLease = resolvedAssets.acquireLease()
        #if canImport(SherpaOnnxC)
        let queue = DispatchQueue(label: "com.vitaliber.speech.\(choice.rawValue)", qos: .userInitiated)
        // 20s为有限解码收尾预算，不是ASR质量/RTF保证；硬件仍先停，再等待。
        var limits = SpeechSessionLimits()
        limits.rotationInterval = 25
        limits.finalizationTimeout = 20
        coordinator = SpeechSessionCoordinator(queue: queue, limits: limits) { request in
            SherpaSpeechSessionDriver(request: request, choice: choice, assets: resolvedAssets)
        }
        #endif
        #if os(iOS)
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil) { _ in Self.unloadWhenIdle() }
        #endif
    }

    deinit { if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) } }
    static func unloadWhenIdle() {
        #if canImport(SherpaOnnxC)
        SherpaSpeechSessionDriver.unloadWhenIdle()
        #endif
    }

    public var capability: TranscriptionCapability {
        #if canImport(SherpaOnnxC)
        guard assets.isPresent(choice), let model = ASRModelCatalog.model(for: choice) else { return .baseline(locales: []) }
        return .init(supportsLongForm: true, maxSegmentSeconds: 30, availableLocales: model.availableLocales,
                     allowsDialectFallback: false, matchesLanguageCode: true)
        #else
        return .baseline(locales: [])
        #endif
    }

    public func transcribe(_ request: TranscriptionRequest, onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
        try await transcribe(request, onPartial: onPartial, onCaptureStarted: {})
    }

    public func transcribe(_ request: TranscriptionRequest, onPartial: (@Sendable (String) -> Void)?,
                           onCaptureStarted: @escaping @Sendable () -> Void) async throws -> TranscriptionResult {
        #if canImport(SherpaOnnxC)
        try assets.checkPackageAuthorization()
        guard ASRModelCatalog.model(for: choice)?.languageCode(for: request.localeIdentifier) != nil else { throw TranscriptionError.engineUnavailable }
        var result = try await coordinator.transcribe(request, onPartial: onPartial, onCaptureStarted: onCaptureStarted)
        result.engineID = choice.rawValue
        result.confidence = 0
        result.confidenceIsAvailable = false
        return result
        #else
        throw TranscriptionError.engineUnavailable
        #endif
    }
    public func finish(sessionID: UUID) async {
        #if canImport(SherpaOnnxC)
        await coordinator.finish(sessionID: sessionID)
        #endif
    }
    public func cancel(sessionID: UUID) async {
        #if canImport(SherpaOnnxC)
        await coordinator.cancel(sessionID: sessionID)
        #endif
    }
    public func discardSession(sessionID: UUID) async {
        #if canImport(SherpaOnnxC)
        await coordinator.discardSession(sessionID: sessionID)
        #endif
    }
    public func endAudio() async {
        #if canImport(SherpaOnnxC)
        await coordinator.finishCapture()
        #endif
    }
}
