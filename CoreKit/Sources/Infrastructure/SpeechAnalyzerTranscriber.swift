// 平台守卫：SpeechAnalyzer / SpeechTranscriber / DictationTranscriber / AssetInventory
// 为 Apple 平台 iOS 26 / macOS 26 起的 Speech 框架模块（ADR-023「升级轨」的正式实装——
// 此前升级轨由 sherpa-onnx 承担，因 ITMS-90208 打包缺陷临时退出构建，生产回落基线轨）。
// 本文件只在 Apple 平台编译；Linux 测试宿主不涉语音硬件。
#if os(iOS) || os(macOS)
import Foundation
import AVFoundation
import Speech
import Domain
import Protocols

/// FR17.15 V3.66：平台升级轨模块档位（同一 SpeechAnalyzer 管线，两种端侧模型族）。
public enum SpeechAnalyzerFlavor: String, Sendable, Equatable {
    /// SpeechTranscriber：通用/对话转写（iOS 26+ 新一代端侧模型）。
    case standard
    /// DictationTranscriber：系统听写同源模型（与系统听写一致的口语形态与兼容面）。
    case dictation
}

/// FR17.15 V3.66：平台升级轨的能力探测与语言资源管理（组装根/模型实验室共用；
/// 生产路径绝不隐式联网下载——资产安装只经实验室显式触发，离线优先红线不破）。
public enum SpeechAnalyzerSupport {
    /// 档位可用性（系统版本 + 设备模型能力）。
    public static func availability(of flavor: SpeechAnalyzerFlavor) -> VoiceEngineAvailability {
        guard #available(iOS 26.0, macOS 26.0, *) else { return .requiresNewerOS }
        switch flavor {
        case .standard:
            return SpeechTranscriber.isAvailable ? .available : .unsupportedDevice
        case .dictation:
            return .available
        }
    }

    /// 系统支持（含可下载）的 locale 标识集。
    /// CI 34654471949 修复：真实 iOS 26 API 中 SpeechTranscriber/Dictation-
    /// Transcriber 的 supportedLocales/installedLocales 均为 **async 属性**，
    /// 同步读取编译报 'async' property access in a function that does not
    /// support concurrency——本族函数随之升 async。
    public static func supportedLocales(of flavor: SpeechAnalyzerFlavor) async -> [String] {
        guard #available(iOS 26.0, macOS 26.0, *) else { return [] }
        switch flavor {
        case .standard: return await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
        case .dictation: return await DictationTranscriber.supportedLocales.map(\.identifier).sorted()
        }
    }

    /// 已安装（离线可直接识别）的 locale 标识集。
    public static func installedLocales(of flavor: SpeechAnalyzerFlavor) async -> [String] {
        guard #available(iOS 26.0, macOS 26.0, *) else { return [] }
        switch flavor {
        case .standard: return await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
        case .dictation: return await DictationTranscriber.installedLocales.map(\.identifier).sorted()
        }
    }

    /// 某 locale 的资源状态（已安装 / 可下载 / 不支持）。
    public static func assetStatus(of flavor: SpeechAnalyzerFlavor, locale identifier: String) async -> VoiceLocaleAssetStatus {
        guard #available(iOS 26.0, macOS 26.0, *) else { return .unavailable }
        let supported = await supportedLocales(of: flavor)
        guard supported.contains(identifier) else { return .unavailable }
        return await installedLocales(of: flavor).contains(identifier) ? .installed : .downloadable
    }

    /// 触发语言资源下载安装（唯一显式入口；返回安装后是否已就绪）。
    public static func install(locale identifier: String, flavor: SpeechAnalyzerFlavor) async -> Bool {
        guard #available(iOS 26.0, macOS 26.0, *) else { return false }
        guard let locale = await supportedLocale(of: flavor, requested: identifier) else { return false }
        do {
            let module = makeModule(flavor: flavor, locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            return true
        } catch {
            return false
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    static func supportedLocale(of flavor: SpeechAnalyzerFlavor, requested: String) async -> Locale? {
        let target = Locale(identifier: requested)
        switch flavor {
        case .standard: return await SpeechTranscriber.supportedLocale(equivalentTo: target)
        case .dictation: return await DictationTranscriber.supportedLocale(equivalentTo: target)
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    static func makeModule(flavor: SpeechAnalyzerFlavor, locale: Locale) -> any SpeechModule {
        switch flavor {
        case .standard:
            return SpeechTranscriber(locale: locale,
                                     transcriptionOptions: [],
                                     reportingOptions: [.volatileResults],
                                     attributeOptions: [])
        case .dictation:
            return DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        }
    }
}

/// FR17.1/FR17.15：平台升级轨转写引擎（SpeechAnalyzer 单次会话 = 一次按住说话）。
///
/// 契约（对齐 tech-spec §5.13 / ADR-023 升级轨）：
/// - 长音频原生支持（`supportsLongForm = true`，无 60s 截断、无需分段续接）；
/// - 资源缺失 / locale 不被平台支持 / 音频格式探测失败 → **整会话回落基线轨**
///   （FR17.17 资产供应契约：绝不因资产缺失瘫痪；回落是每会话决策，不缓存）；
/// - 音频零落盘：采集缓冲经 `AVAudioConverter` 就地转换后直接投喂分析器，
///   本文件不出现任何 `URL`/文件写入（FR17.7 类型级纪律延续）；
/// - 采集拆除沿用 `AudioSessionCapture` 快照对称还原（与另两轨同一出口）。
@available(iOS 26.0, macOS 26.0, *)
public actor SpeechAnalyzerTranscriber: TranscriptionCaptureReporting {
    public nonisolated let capability: TranscriptionCapability
    private let flavor: SpeechAnalyzerFlavor
    private var sessions: [UUID: AnalyzerSession] = [:]
    private var intents: [UUID: AnalyzerStopIntent] = [:]
    /// 回落基线轨委托（FR17.17 每会话决策，不缓存裁决）：resolve() 判定平台轨
    /// 不可服务（版本/设备/locale/资产）时，本会话交给零资产基线轨执行——
    /// 绝不抛 engineUnavailable 让默认档语音输入瘫痪。委托会话的
    /// finish/cancel/discard 按 id 精确路由到基线引擎。
    private var baseline: SFSpeechTranscriber?
    private var delegated: Set<UUID> = []

    public init(flavor: SpeechAnalyzerFlavor = .standard) {
        self.flavor = flavor
        // 初始快照为空集：installedLocales 为 async 属性（CI 34654471949），
        // init 不可 await——真实已安装集由 currentCapability() 的实时探测
        // 返回（唯一运行时读取口；协议能力快照语义不变）。
        capability = .longForm(locales: [])
    }

    public nonisolated func currentCapability() async -> TranscriptionCapability { await Self.probe(flavor: flavor) }

    private nonisolated static func probe(flavor: SpeechAnalyzerFlavor) async -> TranscriptionCapability {
        let installed = Set(await SpeechAnalyzerSupport.installedLocales(of: flavor))
        return .longForm(locales: installed)
    }

    // MARK: - 会话生命周期

    public func transcribe(_ request: TranscriptionRequest,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
        try await transcribe(request, onPartial: onPartial, onCaptureStarted: {})
    }

    public func transcribe(_ request: TranscriptionRequest, onPartial: (@Sendable (String) -> Void)?,
                           onCaptureStarted: @escaping @Sendable () -> Void) async throws -> TranscriptionResult {
        let id = request.sessionID
        return try await withTaskCancellationHandler {
            var result = try await self.run(request: request, onPartial: onPartial, onCaptureStarted: onCaptureStarted)
            // 委托会话的 engineID 由基线引擎如实回填（"classic"），不得被平台轨
            // 档位覆盖——否则 UI 引擎回显与实际服务引擎不符（能力诚实）。
            result.engineID = result.engineID ?? (flavor == .standard ? VoiceEngineChoice.advanced.rawValue : VoiceEngineChoice.dictation.rawValue)
            return result
        } onCancel: {
            Task { await self.cancel(sessionID: id) }
        }
    }

    public func finish(sessionID: UUID) async {
        if delegated.contains(sessionID) { await baselineEngine().finish(sessionID: sessionID); return }
        mark(.finish, for: sessionID)
        sessions[sessionID]?.stopCapture()
    }

    public func cancel(sessionID: UUID) async {
        if delegated.contains(sessionID) { await baselineEngine().cancel(sessionID: sessionID); return }
        mark(.cancel, for: sessionID)
        sessions[sessionID]?.stopCapture()
    }

    public func discardSession(sessionID: UUID) async {
        if delegated.remove(sessionID) != nil {
            await baselineEngine().discardSession(sessionID: sessionID)
            return
        }
        // 复审修正 FIX-C（2026-09-11）：discard 早于 cancel/finish 到达时（调用方
        // 直接退弃会话），采集器仍在跑——此处补幂等停止，否则麦克风/音频会话
        // 会被泄漏到下一次会话（stopCapture 自身幂等，正常路径重复调用无害）。
        sessions[sessionID]?.stopCapture()
        sessions[sessionID] = nil
        intents[sessionID] = nil
    }

    public func endAudio() async {
        for id in delegated { await baselineEngine().finish(sessionID: id) }
        for (id, session) in sessions {
            mark(.finish, for: id)
            session.stopCapture()
        }
    }

    // MARK: - FR17.15 语言资源（实验室入口）

    public func localeAssetStatus(_ localeIdentifier: String) async -> VoiceLocaleAssetStatus {
        await SpeechAnalyzerSupport.assetStatus(of: flavor, locale: localeIdentifier)
    }

    public func prepareLocale(_ localeIdentifier: String) async -> Bool {
        guard await SpeechAnalyzerSupport.install(locale: localeIdentifier, flavor: flavor) else { return false }
        return await SpeechAnalyzerSupport.assetStatus(of: flavor, locale: localeIdentifier) == .installed
    }

    // MARK: - 会话执行

    private func mark(_ intent: AnalyzerStopIntent, for id: UUID) {
        switch (intents[id], intent) {
        case (_, .cancel): intents[id] = .cancel
        case (nil, _): intents[id] = intent
        default: break
        }
    }

    private enum AnalyzerResolution {
        case analyzer(Locale)
        case delegate
    }

    private func resolve(locale identifier: String) async -> AnalyzerResolution {
        guard SpeechAnalyzerSupport.availability(of: flavor) == .available else { return .delegate }
        guard let locale = await SpeechAnalyzerSupport.supportedLocale(of: flavor, requested: identifier) else {
            return .delegate
        }
        // 资产未安装：生产路径不自动下载（离线优先）——整会话回落基线轨，
        // 用户可在「识别引擎实验室」显式安装后升级到平台轨。
        guard await SpeechAnalyzerSupport.installedLocales(of: flavor).contains(locale.identifier) else {
            return .delegate
        }
        return .analyzer(locale)
    }

    private func run(request: TranscriptionRequest,
                     onPartial: (@Sendable (String) -> Void)?,
                     onCaptureStarted: @escaping @Sendable () -> Void) async throws -> TranscriptionResult {
        let id = request.sessionID
        guard sessions[id] == nil else { throw TranscriptionError.engineUnavailable }
        if intents[id] == .cancel || Task.isCancelled { intents[id] = nil; throw CancellationError() }
        if intents[id] == .finish {
            intents[id] = nil
            return TranscriptionResult(text: "", confidence: 0,
                                       resolvedLocale: request.localeIdentifier, segmented: false)
        }
        switch await resolve(locale: request.localeIdentifier) {
        case .delegate:
            // FR17.17：资源缺失 / locale 不支持 / 设备不可用 → 整会话回落基线轨。
            // 委托期间 stop 指令按 id 路由基线引擎；会话结束即解除（单次使用）。
            intents[id] = nil
            delegated.insert(id)
            defer { delegated.remove(id) }
            return try await baselineEngine().transcribe(request, onPartial: onPartial, onCaptureStarted: onCaptureStarted)
        case .analyzer(let locale):
            return try await runAnalyzer(request: request, locale: locale, onPartial: onPartial, onCaptureStarted: onCaptureStarted)
        }
    }

    private func baselineEngine() -> SFSpeechTranscriber {
        if let baseline { return baseline }
        let engine = SFSpeechTranscriber()
        baseline = engine
        return engine
    }

    private func runAnalyzer(request: TranscriptionRequest, locale: Locale,
                             onPartial: (@Sendable (String) -> Void)?,
                             onCaptureStarted: @escaping @Sendable () -> Void) async throws -> TranscriptionResult {
        let id = request.sessionID
        guard await Self.ensureAuthorized() else { throw TranscriptionError.unauthorized }
        if intents[id] == .cancel || Task.isCancelled { intents[id] = nil; throw CancellationError() }

        let module = SpeechAnalyzerSupport.makeModule(flavor: flavor, locale: locale)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            intents[id] = nil
            throw TranscriptionError.engineUnavailable
        }

        let session = AnalyzerSession(id: id, locale: locale, module: module,
                                      analyzerFormat: analyzerFormat, onPartial: onPartial)
        sessions[id] = session
        defer { sessions[id] = nil; intents[id] = nil; session.stopCapture() }

        if intents[id] == .cancel { throw CancellationError() }
        if intents[id] == .finish {
            return TranscriptionResult(text: "", confidence: 0,
                                       resolvedLocale: locale.identifier, segmented: false)
        }
        do {
            try session.startCapture()
            onCaptureStarted()
        } catch {
            throw error
        }
        session.startResultPump()

        async let analysis: CMTime? = session.analyze()
        // 松手/finish/cancel 均由外部意图驱动等待（与基线轨同一控制模型）。
        while session.captureFailure == nil {
            if Task.isCancelled { break }
            if intents[id] != nil && intents[id] != .running { break }
            do { try await Task.sleep(nanoseconds: 30_000_000) }
            catch { break }
        }
        let cancelled = intents[id] == .cancel || Task.isCancelled
        session.stopCapture()
        session.finishInput()

        let lastSampleTime: CMTime?
        do { lastSampleTime = try await analysis }
        catch {
            await session.abort()
            if let failure = session.captureFailure { throw failure }
            throw error
        }
        if cancelled {
            await session.abort()
            throw CancellationError()
        }
        do {
            if let lastSampleTime {
                try await session.finalize(through: lastSampleTime)
            } else {
                try await session.finalizeThroughEndOfInput()
            }
        } catch {
            let result = session.makeResult(localeIdentifier: locale.identifier)
            if result.text.isEmpty, let failure = session.captureFailure { throw failure }
            return result
        }
        await session.awaitResultsEnd()
        if let failure = session.captureFailure, session.displayText.isEmpty { throw failure }
        return session.makeResult(localeIdentifier: locale.identifier)
    }

    private static func ensureAuthorized() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            guard granted else { return false }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { return false }
        }
        return true
    }
}

// MARK: - 停止意图

enum AnalyzerStopIntent: Sendable, Equatable {
    case running, finish, cancel
}

// MARK: - 单次会话（采集 + 分析 + 结果拼装）

@available(iOS 26.0, macOS 26.0, *)
final class AnalyzerSession: @unchecked Sendable {
    struct Piece {
        var start: Double
        var end: Double
        var text: String
        var isFinal: Bool
    }

    let id: UUID
    let locale: Locale

    private let analyzer: SpeechAnalyzer
    private let stream: AsyncStream<AnalyzerInput>
    private let builder: AsyncStream<AnalyzerInput>.Continuation
    private let standardModule: SpeechTranscriber?
    private let dictationModule: DictationTranscriber?
    private let onPartial: (@Sendable (String) -> Void)?
    private let lock = NSLock()

    private let analyzerFormat: AVAudioFormat
    private var pieces: [Piece] = []
    private var failure: Error?
    private var lastPublished = ""
    private var resultsTask: Task<Void, Never>?

    // 采集侧状态只在转录 actor 上访问（stopCapture 幂等）。
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    #if os(iOS)
    private var sessionState: AudioSessionCapture.State?
    #endif

    init(id: UUID, locale: Locale, module: any SpeechModule,
         analyzerFormat: AVAudioFormat, onPartial: (@Sendable (String) -> Void)?) {
        self.id = id
        self.locale = locale
        self.onPartial = onPartial
        self.analyzerFormat = analyzerFormat
        self.analyzer = SpeechAnalyzer(modules: [module])
        self.standardModule = module as? SpeechTranscriber
        self.dictationModule = module as? DictationTranscriber
        let (stream, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.stream = stream
        self.builder = builder
    }

    // MARK: 音频采集

    func startCapture() throws {
        #if os(iOS)
        let prior = AudioSessionCapture.remember()
        do { try AudioSessionCapture.activateRecordSession() }
        catch {
            AudioSessionCapture.restore(prior)
            throw error
        }
        sessionState = prior
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let captureFormat = input.outputFormat(forBus: 0)
        guard captureFormat.sampleRate > 0, captureFormat.channelCount > 0 else {
            throw TranscriptionError.engineUnavailable
        }
        let feeder = AnalyzerFeeder(captureFormat: captureFormat, analyzerFormat: analyzerFormat,
                                    builder: builder)
        input.installTap(onBus: 0, bufferSize: 1024, format: captureFormat) { [weak self] buffer, _ in
            guard buffer.frameLength > 0 else { return }
            if !feeder.feed(buffer) { self?.noteFailure(TranscriptionError.engineUnavailable) }
        }
        tapInstalled = true
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.noteFailure(TranscriptionError.engineUnavailable)
            }
        // 审查修复：中断（来电等）必须快速失败——基线轨与 sherpa 轨均监听
        // AVAudioSession.interruptionNotification，本轨缺失时来电期间采集停摆、
        // 等待循环永无失败信号，UI 卡在「录音中」直到松手。
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: nil) { [weak self] note in
                guard let userInfo = note.userInfo,
                      let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: rawType) == .began else { return }
                self?.noteFailure(TranscriptionError.engineUnavailable)
            }
        #endif
        engine.prepare()
        try engine.start()
    }

    func stopCapture() {
        #if os(iOS)
        let hasSessionState = sessionState != nil
        #else
        let hasSessionState = false
        #endif
        guard engine != nil || tapInstalled || configurationObserver != nil || interruptionObserver != nil || hasSessionState else { return }
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let engine {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        engine = nil
        tapInstalled = false
        #if os(iOS)
        if let prior = sessionState {
            AudioSessionCapture.restore(prior)
            sessionState = nil
        }
        #endif
    }

    func finishInput() { builder.finish() }

    // MARK: 分析

    func analyze() async throws -> CMTime? {
        try await analyzer.analyzeSequence(stream)
    }

    func finalize(through time: CMTime) async throws {
        try await analyzer.finalizeAndFinish(through: time)
    }

    func finalizeThroughEndOfInput() async throws {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    func abort() async {
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
    }

    // MARK: 结果收集

    func startResultPump() {
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let module = self.standardModule {
                    for try await result in module.results {
                        self.handle(text: String(result.text.characters), isFinal: result.isFinal,
                                    range: result.range)
                    }
                } else if let module = self.dictationModule {
                    for try await result in module.results {
                        self.handle(text: String(result.text.characters), isFinal: result.isFinal,
                                    range: result.range)
                    }
                }
            } catch is CancellationError {
                // 审查修复：abort() 有意取消结果泵——取消不是采集/分析故障，
                // 不得经 noteFailure 抢占真实的 analyze() 错误（旧实现竞态
                // 下把真错误替换为 CancellationError，用户口述内容静默丢弃）。
            } catch {
                self.noteFailure(error)
            }
            self.publish()
        }
    }

    func awaitResultsEnd() async {
        await resultsTask?.value
    }

    /// 重叠区间被新结果取代（volatile → final 的替换语义），按时间序拼接。
    /// 乱序/重复投递由区间去重保证幂等——与基线轨 `PartialGate` 同一取向。
    private func handle(text: String, isFinal: Bool, range: CMTimeRange) {
        let start = range.start.seconds
        let end = range.end.seconds
        lock.lock()
        if start.isFinite, end.isFinite, end >= start {
            pieces.removeAll { $0.start < end && start < $0.end }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                pieces.append(Piece(start: start, end: end, text: trimmed, isFinal: isFinal))
                pieces.sort { $0.start < $1.start }
            }
        }
        lock.unlock()
        publish()
    }

    private func publish() {
        let display = displayText
        lock.lock()
        let changed = display != lastPublished
        if changed { lastPublished = display }
        lock.unlock()
        guard changed, !display.isEmpty else { return }
        onPartial?(display)
    }

    /// 文本拼接：CJK 直接相接；拉丁字符短语之间补空格（英文短语边界可读性）。
    var displayText: String {
        lock.lock()
        defer { lock.unlock() }
        var output = ""
        for piece in pieces {
            if let last = output.last, let first = piece.text.first,
               last.isLetter || last.isNumber, first.isLetter || first.isNumber {
                let lastIsCJK = last.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                let firstIsCJK = first.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                if !lastIsCJK && !firstIsCJK { output.append(" ") }
            }
            output.append(piece.text)
        }
        return output
    }

    var captureFailure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func noteFailure(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    // MARK: 结果

    func makeResult(localeIdentifier: String) -> TranscriptionResult {
        lock.lock()
        let hasVolatile = pieces.contains { !$0.isFinal }
        lock.unlock()
        return TranscriptionResult(text: displayText,
                                   confidence: hasVolatile ? 0 : 0.85,
                                   resolvedLocale: localeIdentifier,
                                   segmented: false,
                                   segments: displayText.isEmpty ? [] : [displayText],
                                   completion: hasVolatile ? .partial : .final)
    }
}

/// 音频线程转换器：采集格式 → 分析器格式。配置不可变（构造后不修改），
/// 仅 `failed` 标志受锁保护；采集缓冲一律拷贝后投喂（tap 缓冲会被引擎复用）。
@available(iOS 26.0, macOS 26.0, *)
private final class AnalyzerFeeder: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let analyzerFormat: AVAudioFormat
    private let builder: AsyncStream<AnalyzerInput>.Continuation
    private let lock = NSLock()
    private var failed = false

    init(captureFormat: AVAudioFormat, analyzerFormat: AVAudioFormat,
         builder: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzerFormat = analyzerFormat
        self.builder = builder
        let sameFormat = captureFormat.isEqual(analyzerFormat)
        self.converter = sameFormat ? nil : AVAudioConverter(from: captureFormat, to: analyzerFormat)
        if !sameFormat, converter == nil { failed = true }   // 构造期无并发，直接写
    }

    /// 音频线程调用；返回是否成功（false = 转换/分配失败，转录层据此记失败）。
    @discardableResult
    func feed(_ input: AVAudioPCMBuffer) -> Bool {
        lock.lock()
        let alive = !failed
        lock.unlock()
        guard alive else { return false }
        guard let converter else {
            guard let copy = Self.copy(of: input) else { markFailed(); return false }
            builder.yield(AnalyzerInput(buffer: copy))
            return true
        }
        let ratio = analyzerFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
            markFailed()
            return false
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        switch status {
        case .haveData, .inputRanDry:
            if output.frameLength > 0 { builder.yield(AnalyzerInput(buffer: output)) }
            return true
        default:
            markFailed()
            return false
        }
    }

    private static func copy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in source.indices {
            guard destination.indices.contains(index),
                  source[index].mDataByteSize == destination[index].mDataByteSize,
                  let from = source[index].mData, let to = destination[index].mData else { return nil }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        return copy
    }

    private func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }
}
#endif
