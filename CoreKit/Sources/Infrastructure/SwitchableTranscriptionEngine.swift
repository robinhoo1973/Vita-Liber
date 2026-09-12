import Foundation
import Domain
import Protocols

/// FR17.15：选择锁定在一次按压，停止按ID精确路由；早停不依赖委托是否已创建。
actor SwitchableTranscriptionEngine: TranscriptionCaptureReporting {
    private enum Stop { case finish, cancel }
    private let choiceProvider: @Sendable () -> VoiceEngineChoice
    private let builder: @Sendable (VoiceEngineChoice) -> any TranscriptionEngine
    private var serving: [UUID: any TranscriptionEngine] = [:]
    private var stops: [UUID: Stop] = [:]
    private var retired: [UUID] = []
    private var captureOwner: UUID?
    private var cached: (VoiceEngineChoice, any TranscriptionEngine)?

    init(choiceProvider: @escaping @Sendable () -> VoiceEngineChoice,
         builder: @escaping @Sendable (VoiceEngineChoice) -> any TranscriptionEngine = { TranscriptionEngineBuilder.make(choice: $0) }) {
        self.choiceProvider = choiceProvider
        self.builder = builder
    }

    /// 同步只读能力面：代理实际服务长音频引擎（sherpa/平台轨），同步属性
    /// 如实标注 long-form 而非 baseline（60s 分段语义）；locale 集合为空
    /// 表示「必须经 currentCapability() 异步探测」——不得把空集合读成
    /// 「全语言不支持」而误触发手输降级。
    public nonisolated var capability: TranscriptionCapability { .longForm(locales: []) }

    func currentCapability() async -> TranscriptionCapability {
        let choice = choiceProvider()
        if choice == .auto { return await TranscriptionEngineBuilder.automaticCapability() }
        return await delegate(for: choice).currentCapability()
    }

    func transcribe(_ request: TranscriptionRequest,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
        try await transcribe(request, onPartial: onPartial, onCaptureStarted: {})
    }

    func transcribe(_ request: TranscriptionRequest, onPartial: (@Sendable (String) -> Void)?,
                    onCaptureStarted: @escaping @Sendable () -> Void) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let id = request.sessionID
        guard serving[id] == nil, !retired.contains(id) else { throw TranscriptionError.engineUnavailable }
        if let intent = stops.removeValue(forKey: id) {
            retire(id)
            if intent == .cancel { throw CancellationError() }
            return .init(text: "", confidence: 0, resolvedLocale: request.localeIdentifier, segmented: false)
        }
        let selected = choiceProvider()
        // 审计修正（round3）：auto 解析改用 builder 的**过闸**版本（缺件随包模型回落
        // 平台轨/基线轨），绝不把缺件引擎交给会话（否则每次必抛 engineUnavailable）。
        let choice = selected == .auto ? TranscriptionEngineBuilder.automaticChoice(locale: request.localeIdentifier) : selected
        let engine = delegate(for: choice)
        let previous = captureOwner.flatMap { serving[$0].map { ($0, captureOwner) } }
        serving[id] = engine
        captureOwner = id
        defer {
            serving[id] = nil
            if captureOwner == id { captureOwner = nil }
            retire(id)
        }
        // 停止旧硬件后再启动新会话；原生推理的迟到结果由委托按ID丢弃。
        if let (previousEngine, previousID) = previous, let previousID { await previousEngine.cancel(sessionID: previousID) }
        guard captureOwner == id else { throw CancellationError() }
        if stops[id] == .cancel { throw CancellationError() }
        if stops[id] == .finish { await engine.finish(sessionID: id) }
        var result: TranscriptionResult
        if let reporting = engine as? any TranscriptionCaptureReporting {
            result = try await reporting.transcribe(request, onPartial: onPartial, onCaptureStarted: onCaptureStarted)
        } else {
            onCaptureStarted()
            result = try await engine.transcribe(request, onPartial: onPartial)
        }
        try Task.checkCancellation()
        guard stops[id] != .cancel else { throw CancellationError() }
        result.engineID = result.engineID ?? choice.rawValue
        return result
    }

    func finish(sessionID: UUID) async {
        guard !retired.contains(sessionID) else { return }
        if stops[sessionID] != .cancel { stops[sessionID] = .finish }
        await serving[sessionID]?.finish(sessionID: sessionID)
        // Hardware has stopped, while the old result may still drain. A new press must not cancel that result.
        if captureOwner == sessionID { captureOwner = nil }
    }

    func cancel(sessionID: UUID) async {
        guard !retired.contains(sessionID) else { return }
        stops[sessionID] = .cancel
        await serving[sessionID]?.cancel(sessionID: sessionID)
    }

    func discardSession(sessionID: UUID) async {
        stops[sessionID] = .cancel
        if let engine = serving[sessionID] { await engine.discardSession(sessionID: sessionID) }
        retire(sessionID)
    }

    func endAudio() async {
        if let id = captureOwner { await finish(sessionID: id) }
    }

    func localeAssetStatus(_ localeIdentifier: String) async -> VoiceLocaleAssetStatus {
        let choice = choiceProvider()
        return await delegate(for: choice == .auto ? TranscriptionEngineBuilder.automaticChoice(locale: localeIdentifier) : choice)
            .localeAssetStatus(localeIdentifier)
    }

    func prepareLocale(_ localeIdentifier: String) async -> Bool {
        let choice = choiceProvider()
        // 审查修复：auto 档必须先按 locale 解析实际服务档位再判可安装性——
        // 且必须与 localeAssetStatus 同用一个**门控**解析器（旧实现对 auto
        // 用未门控目录：zh 恒解析 .qwen3、requiresLocaleAssets==false 恒
        // return false，实验室在「auto + 平台轨回落」场景显示可下载按钮
        // 却必然安装失败——owner round10 实测）。
        let resolved = choice == .auto ? TranscriptionEngineBuilder.automaticChoice(locale: localeIdentifier) : choice
        guard resolved.requiresLocaleAssets else { return false }
        return await delegate(for: resolved).prepareLocale(localeIdentifier)
    }

    private func delegate(for choice: VoiceEngineChoice) -> any TranscriptionEngine {
        if let cached, cached.0 == choice { return cached.1 }
        cached = nil
        let engine = builder(choice)
        cached = (choice, engine)
        return engine
    }

    private func retire(_ id: UUID) {
        stops[id] = nil
        if !retired.contains(id) { retired.append(id) }
        if retired.count > 256 { retired.removeFirst(retired.count - 256) }
    }
}
