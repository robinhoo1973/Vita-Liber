import Foundation
import os
import Domain
import Protocols
#if os(iOS)
import AVFoundation
import SherpaOnnx

/// ADR-023 主轨（V3.102）：sherpa-onnx FunASR-Nano 端侧离线语音识别。
///
/// 资产缺失/加载失败时由组合根回落基线轨 `SFSpeechTranscriber`（功能完备、零资产），
/// 生产装配绝不回落契约桩（FR17.6 降级语义：先试全部真实引擎，不可用才降级手输）。
///
/// 会话模型（FR17.1 / tech-spec §5.13）：
/// - `transcribe` = 一次按住说话：启动采集后挂起，直到 `finish(sessionID:)`（松手）
///   或 `cancel(sessionID:)`/`endAudio()` 恢复；
/// - 采集期间部分结果泵每 ~0.8s 对新到样本增量解码，`onPartial` 回传
///   「已提交段 + 当前部分」——FR17.1 部分结果流实时上屏，不得只在松手后出全文；
/// - `maxSegmentSeconds - 5` 计时主动换段（TranscriptSessionAccumulator 同口径）：
///   解码提交该段、出清缓冲——长录音不丢字且内存有界；
/// - 松手收尾解码剩余缓冲，返回各段拼接（segments 逐段可回溯）。
///
/// 音频零落盘（FR17.7）：PCM 缓冲仅存在于内存 `SampleBuffer`，协议签名无
/// URL/Data 通道，调用方拿不到也交不出音频字节。
public actor SherpaOnnxTranscriber: TranscriptionEngine {
    public nonisolated let capability: TranscriptionCapability

    private let recognizer: SherpaOnnxOfflineRecognizer
    private let modelSampleRate = 16_000

    // 采集状态（引擎单会话；VoiceDictationModel 已按 press 串行，引擎侧再守卫）
    private var audioEngine: AVAudioEngine?
    private var sessionActive = false
    private var pendingSession: (id: UUID, continuation: CheckedContinuation<Void, Error>)?

    // 会话内累计状态（Domain 纯值累加器：引擎与视图模型共用，见 Domain/TranscriptSession.swift）
    private var accumulator = TranscriptSessionAccumulator()
    /// 上次部分结果解码窗口的起点（避免每次对全窗重复解码）
    private var lastPartialSampleCount = 0

    /// FR17.17 资产供应契约：缺失/损坏即记可诊断事件（回落由工厂承担，
    /// 引擎侧只负责把「为什么没有主轨」留下可查痕迹）
    private static let assetLogger = Logger(subsystem: "com.vitaliber", category: "sherpa.assets")

    // MARK: - 实时线程安全的样本缓冲

    /// tap 回调运行在 AVAudioEngine 实时线程，不能触碰 actor 状态——
    /// 缓冲下沉为锁保护类（Swift 5/6 并发模式均可编译；锁只护样本数组）。
    private final class SampleBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        var count: Int { lock.withLock { samples.count } }
        func append(_ new: [Float]) { lock.withLock { samples.append(contentsOf: new) } }
        /// 取走全部样本（旋转换段出清用）
        @discardableResult
        func drain() -> [Float] {
            lock.withLock {
                defer { samples.removeAll(keepingCapacity: true) }
                return samples
            }
        }
        /// 从 index 起的尾部（index 越界视为空）
        func tail(from index: Int) -> [Float] {
            lock.withLock { index < samples.count ? Array(samples[index...]) : [] }
        }
        func clear() { lock.withLock { samples.removeAll(keepingCapacity: true) } }
    }
    private let buffer = SampleBuffer()

    /// 采集闭包捕获盒：AVAudioFormat/AVAudioConverter 非 Sendable，
    /// 装箱后 @Sendable tap 闭包在 Swift 6 严格并发下亦可编译。
    private final class TapContext: @unchecked Sendable {
        let targetFormat: AVAudioFormat
        let converter: AVAudioConverter
        let hwSampleRate: Double
        let modelSampleRate: Int
        init(targetFormat: AVAudioFormat, converter: AVAudioConverter,
             hwSampleRate: Double, modelSampleRate: Int) {
            self.targetFormat = targetFormat
            self.converter = converter
            self.hwSampleRate = hwSampleRate
            self.modelSampleRate = modelSampleRate
        }
    }

    // MARK: - Init

    public init?() {
        // 注意：sherpa-onnx 包装器 init 不可失败，模型加载失败会 fatalError——
        // makeRecognizer 已预检文件存在与非零体积；文件损坏的残余风险由
        // FR17.17 资产供应契约（§2.2 sha256 清单校验）兜底，校验失败回落基线轨。
        guard let recognizer = Self.makeRecognizer(hotwords: "") else {
            // FR17.17：缺失即记可诊断事件（此前静默回落，事后无从区分
            // 「资产未打包」与「文件损坏」）
            Self.assetLogger.error("sherpa FunASR-Nano 资产预检失败（缺件/零体积）——回落 SFSpeech 降级轨")
            return nil
        }
        self.recognizer = recognizer
        capability = Self.probeCapability()
    }

    // MARK: - TranscriptionEngine

    public nonisolated func currentCapability() async -> TranscriptionCapability { capability }

    public nonisolated func transcribe(
        _ request: TranscriptionRequest,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> TranscriptionResult {
        try await _transcribe(request, onPartial: onPartial)
    }

    public nonisolated func finish(sessionID: UUID) async {
        await _resumeSession(id: sessionID)
    }

    public nonisolated func cancel(sessionID: UUID) async {
        await _cancelSession(id: sessionID)
    }

    public nonisolated func discardSession(sessionID: UUID) async {
        await _cancelSession(id: sessionID)
    }

    public nonisolated func endAudio() async {
        await _resumeAnySession()
    }

    // MARK: - 会话实现

    private func _transcribe(
        _ request: TranscriptionRequest,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> TranscriptionResult {
        // 会话超驰（异常路径防悬挂）：上一会话未结先按取消结清
        if let previous = pendingSession {
            pendingSession = nil
            previous.continuation.resume(throwing: CancellationError())
        }
        stopCaptureSync(clearBuffer: true)
        buffer.clear()
        accumulator = TranscriptSessionAccumulator()
        lastPartialSampleCount = 0

        // 词表注入（FR17.15 混说词表 ≤100）：主语言 + 混说开关开时注入
        // 已确认药名/医疗单位/英文医学词；空词表 = 不注入（混说开关关）。
        if !request.contextualStrings.isEmpty {
            let hotwords = request.contextualStrings
                .prefix(MixedSpeechVocabulary.limit)
                .joined(separator: "\n")
            applyHotwords(hotwords)
        }

        try await startCapture()

        // 部分结果泵：采集期间定时增量解码（子任务非结构化，defer 显式收）
        let pump = Task { [weak self] in
            while !Task.isCancelled {
                // 睡眠取消 = 泵停（CancellationError 是预期控制流，不是错误）
                do { try await Task.sleep(nanoseconds: 800_000_000) }
                catch { break }
                if Task.isCancelled { break }
                await self?.pumpPartial(onPartial: onPartial)
            }
        }

        do {
            try await withTaskCancellationHandler {
                // 显式标注 CheckedContinuation<Void, Error>：泛型 T 无法从 body 推断
                // （body 返回 Void，T 不由 body 锚定）
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    // 取消可能在挂起注册前到达（startCapture 期间）——先查后挂，
                    // 否则被取消的任务会永远悬挂、采集不停
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    pendingSession = (request.sessionID, continuation)
                }
            } onCancel: {
                Task { await self._cancelSession(id: request.sessionID) }
            }
        } catch {
            pump.cancel()
            stopCaptureSync(clearBuffer: true)
            throw error
        }
        pump.cancel()

        // 松手收尾：解码剩余未解码样本（整窗解码，保证收尾质量）。
        // 原子 drain()：取走与清空同一把锁内完成——tap 已摘除、无并发追加，
        // 与旋转提交共用同一语义（缓冲只含未解码样本）。
        stopCaptureSync(clearBuffer: false)
        let undecoded = buffer.drain()
        if !undecoded.isEmpty {
            accumulator.updatePartial(decode(undecoded))
        }
        let segments = accumulator.finish()
        let text = segments.filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else {
            throw TranscriptionError.noSpeechDetected
        }
        onPartial?(text)
        let locale = request.localeIdentifier
        return TranscriptionResult(
            text: text,
            confidence: Self.confidence(for: locale),
            resolvedLocale: Self.resolvedLocale(for: locale),
            segmented: segments.count > 1,
            segments: segments,
            completion: .final
        )
    }

    private func pumpPartial(onPartial: (@Sendable (String) -> Void)?) {
        guard pendingSession != nil else { return }
        let count = buffer.count
        let newSamples = count - lastPartialSampleCount
        // 至少 0.5s 新音频才做一次部分解码（控制 CPU；短片段解码质量差但仅作显示）
        guard newSamples >= modelSampleRate / 2 else { return }

        // 主动换段（FR17.1：上限前 5s 换段；长录音不丢字 + 内存有界）。
        // 提交整窗解码：只提交最新增量窗会把此前 ~55s 音频永久丢弃（丢字）。
        // 原子 drain()（取走即清空，单次加锁）：旧实现 tail()+drain() 两步之间
        // tap 实时线程可追加新样本——追加样本被 drain 清掉却未解码，旋转边界
        // 丢词（概率小但每次旋转都开奖；缓冲只含未解码样本，drain 即整窗）。
        let rotationLimit = Double(max(5, capability.maxSegmentSeconds - 5))
        if Double(count) / Double(modelSampleRate) >= rotationLimit {
            accumulator.commit(decode(buffer.drain()))
            lastPartialSampleCount = 0
            onPartial?(accumulator.displayText)
            return
        }
        let window = buffer.tail(from: lastPartialSampleCount)
        lastPartialSampleCount = count
        accumulator.updatePartial(decode(window))
        onPartial?(accumulator.displayText)
    }

    private func decode(_ samples: [Float]) -> String {
        guard !samples.isEmpty else { return "" }
        let result = recognizer.decode(samples: samples, sampleRate: modelSampleRate)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 会话收尾（按 sessionID 单次生效）

    private func _resumeSession(id: UUID) {
        guard let session = pendingSession, session.id == id else { return }
        pendingSession = nil
        session.continuation.resume()
    }

    private func _cancelSession(id: UUID) {
        // 未登记的废弃请求：不得清场他人会话（协议契约「IDs are single-use」）
        guard let session = pendingSession, session.id == id else { return }
        pendingSession = nil
        session.continuation.resume(throwing: CancellationError())
    }

    private func _resumeAnySession() {
        guard let session = pendingSession else { return }
        pendingSession = nil
        session.continuation.resume()
    }

    // MARK: - 音频采集

    private func startCapture() async throws {
        guard audioEngine == nil else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .denied:
            throw TranscriptionError.unauthorized
        default:
            break
        }
        do { try session.setCategory(.record, mode: .measurement, options: [.duckOthers]) }
        catch { throw TranscriptionError.engineUnavailable }
        do { try session.setActive(true) }
        catch { throw TranscriptionError.engineUnavailable }
        sessionActive = true
        #endif

        let engine = AVAudioEngine()
        var tapInstalled = false
        do {
            let input = engine.inputNode
            let hwFormat = input.outputFormat(forBus: 0)
            guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
                throw TranscriptionError.engineUnavailable
            }
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(modelSampleRate),
                channels: 1,
                interleaved: false
            ), let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
                throw TranscriptionError.engineUnavailable
            }

            let tap = TapContext(
                targetFormat: targetFormat, converter: converter,
                hwSampleRate: hwFormat.sampleRate, modelSampleRate: modelSampleRate
            )
            let buffer = buffer
            input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { pcm, _ in
                guard pcm.frameLength > 0 else { return }
                let outputFrameCapacity = AVAudioFrameCount(
                    Double(pcm.frameLength) * Double(tap.modelSampleRate) / tap.hwSampleRate
                ) + 16
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: tap.targetFormat, frameCapacity: outputFrameCapacity
                ) else { return }
                // 输入块纪律（审查修复）：同一 chunk 只供给一次——converter 会反复
                // 调用输入块填满输出缓冲，若每次都返回同一 buffer，会把 chunk 头部
                // 重复转换（每 4096 帧 ≈16 帧复制），识别器输入出现周期性回声
                var supplied = false
                var conversionError: NSError?
                _ = tap.converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                    if supplied {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    outStatus.pointee = .haveData
                    return pcm
                }
                guard outputBuffer.frameLength > 0,
                      let ptr = outputBuffer.floatChannelData?[0] else { return }
                buffer.append(Array(UnsafeBufferPointer(start: ptr, count: Int(outputBuffer.frameLength))))
            }
            tapInstalled = true

            audioEngine = engine
            engine.prepare()
            try engine.start()
        } catch {
            // 起不来的引擎必须彻底拆除（审查修复）：无论失败发生在 tap 前还是后，
            // 已装的 tap 必须摘除（残留 tap 会让下一次 installTap 在共享输入总线 0
            // 上抛 NSException），会话类别必须还原（.record 常驻会让其后
            // FR17.13 回读/FR19.3 播报路由到听筒、麦克风隐私指示常亮）。
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
            }
            audioEngine = nil
            deactivateAudioSession()
            throw (error as? TranscriptionError) ?? TranscriptionError.engineUnavailable
        }
    }

    /// 会话类别是共享单例状态：停在 `.record` 会把其后 FR17.13 回读 / FR19.3
    /// 播报路由到听筒——停采后经采集拆除单一出口（AudioSessionTeardown）
    /// 还原到 `.playback` 再停用。
    private func deactivateAudioSession() {
        #if os(iOS)
        guard sessionActive else { return }
        AudioSessionTeardown.restorePlaybackAfterCapture()
        sessionActive = false
        #endif
    }

    private func stopCaptureSync(clearBuffer: Bool) {
        if clearBuffer { buffer.clear() }
        guard let engine = audioEngine else { return }
        audioEngine = nil
        // 拆除顺序：先摘 tap 断流，再停引擎（松手收尾不丢字）
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        deactivateAudioSession()
    }

    // MARK: - 模型配置

    /// 资产预检（FR17.17 资产供应契约）：缺件/空文件一律回落基线轨，
    /// 不得进入 sherpa-onnx 包装器的 fatalError 路径。纯 Swift 返回——
    /// 不含 SherpaOnnxC 模块类型。
    private static func assetPaths() -> [String]? {
        guard let bundle = Bundle.main.path(forResource: "SherpaOnnxModels", ofType: nil) else {
            return nil
        }
        let dir = (bundle as NSString).appendingPathComponent("funasr-nano")
        let paths = [
            "encoder_adaptor.onnx", "llm.gguf", "embedding.onnx", "tokenizer.txt",
        ].map { (dir as NSString).appendingPathComponent($0) }
        for path in paths {
            let attrs: [FileAttributeKey: Any]
            do { attrs = try FileManager.default.attributesOfItem(atPath: path) }
            catch { return nil }
            if (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 0 { return nil }
        }
        return paths
    }

    /// 构造识别器（含资产预检 + FunASR-Nano 四件套专用槽位 + 热词）。
    /// 注意：配置类型来自 SherpaOnnxC 模块（上游 xcframework modulemap
    /// 定义，不是 SPM 公开产品）——客户端代码**不得命名其类型**，配置
    /// 构造与消费必须同处一个函数内、全程类型推断（CI 实证：
    /// 「cannot find type ... in scope」）。`hotwords` 为会话级词表注入
    /// （FR17.15，≤100 词）。
    private static func makeRecognizer(hotwords: String) -> SherpaOnnxOfflineRecognizer? {
        guard let paths = assetPaths() else { return nil }
        var cfg = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80),
            modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: "",
                numThreads: 2,
                provider: "cpu",
                debug: 0,
                funasrNano: sherpaOnnxOfflineFunASRNanoModelConfig(
                    encoderAdaptor: paths[0],
                    llm: paths[1],
                    embedding: paths[2],
                    tokenizer: paths[3],
                    hotwords: hotwords)),
            lmConfig: sherpaOnnxOfflineLMConfig(),
            decodingMethod: "greedy_search",
            maxActivePaths: 4)
        return SherpaOnnxOfflineRecognizer(config: &cfg)
    }

    /// 会话级热词注入（FR17.15）：重建同构配置并 setConfig。与
    /// makeRecognizer 的构造重复是刻意的——配置类型不可命名（见上），
    /// 无法提取返回该类型的共享构造函数。
    private func applyHotwords(_ hotwords: String) {
        guard let paths = Self.assetPaths() else { return }
        var cfg = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80),
            modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: "",
                numThreads: 2,
                provider: "cpu",
                debug: 0,
                funasrNano: sherpaOnnxOfflineFunASRNanoModelConfig(
                    encoderAdaptor: paths[0],
                    llm: paths[1],
                    embedding: paths[2],
                    tokenizer: paths[3],
                    hotwords: hotwords)),
            lmConfig: sherpaOnnxOfflineLMConfig(),
            decodingMethod: "greedy_search",
            maxActivePaths: 4)
        recognizer.setConfig(config: &cfg)
    }

    // MARK: - 能力与置信度（能力诚实，FR17.15/V3.94）

    private static func probeCapability() -> TranscriptionCapability {
        // 六语种选择面 = Domain 方言矩阵单一事实源（FR17.15 能力矩阵不硬编码第二份）；
        // FunASR-Nano 为普通话基线模型：yue/en/nan/wuu/川 = T2 尽力识别
        // （热词注入 + 低置信强制复核），resolvedLocale 如实回显普通话。
        let locales = Set(EngineCapabilityProfile.dialectMatrix()
            .flatMap { $0.supportedLocales.map(\.identifier) })
        return TranscriptionCapability(
            supportsLongForm: true,  // 引擎内部自换段，无 60s 截断
            maxSegmentSeconds: 60,   // 主动换段间隔（FR17.1：上限前 5s 换段）
            availableLocales: locales
        )
    }

    /// T2 尽力识别：实际解码语言恒为普通话基线模型——resolvedLocale 如实回显，
    /// `isBestEffortFallback` 由 VoiceDictationModel 对比请求语言得出。
    private static func resolvedLocale(for requested: String) -> String {
        TranscriptionLocale.normalizedIdentifier(requested) == "zh-hans-cn"
            ? "zh-Hans-CN"
            : TranscriptionSegmentation.fallbackLocale
    }

    /// V3.94 置信度纪律：不得恒 0.9。T1（普通话）0.85；T2 尽力识别 0.4——
    /// 落 <0.5，FR17.4 低置信强制复核闸可达（FR17.15「低置信强制复核」）。
    private static func confidence(for requested: String) -> Double {
        TranscriptionLocale.normalizedIdentifier(requested) == "zh-hans-cn" ? 0.85 : 0.4
    }
}
#else
/// 非 iOS 编译占位（macOS/Linux 测试宿主）：sherpa-onnx 二进制仅在 iOS
/// 链接（Package.swift 产品条件 .iOS）——主轨在非 iOS 平台恒不可用，
/// 工厂回落基线轨 SFSpeechTranscriber（功能完备、零资产）。
/// 生产（iOS）路径不受本占位影响。
public actor SherpaOnnxTranscriber: TranscriptionEngine {
    public nonisolated let capability: TranscriptionCapability
    public init?() { self.capability = .baseline(); return nil }
    public func transcribe(_ request: TranscriptionRequest,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
        throw TranscriptionError.engineUnavailable
    }
}
#endif
