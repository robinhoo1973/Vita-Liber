#if canImport(SherpaOnnxC)
import Foundation
import AVFoundation
import Domain
import Protocols

struct CapturedSpeechAudio: @unchecked Sendable { let pcm: AVAudioPCMBuffer }

/// 控制队列只处理采集/格式转换；串行推理队列负责模型与解码。
/// 有限mailbox不会为每个tap创建一个无界Task或把大量buffer挂在DispatchQueue上。
final class SherpaSpeechSessionDriver: SpeechSessionDriver, @unchecked Sendable {
    private static let inferenceQueue = DispatchQueue(label: "com.vitaliber.speech.inference", qos: .userInitiated)
    private static let pool = RuntimePool()
    /// 会话结束后运行时常驻时长：A13 加载 Qwen3 需数秒，连续按压间不得重载（round2 A-N2）。
    static let idleEvictionSeconds: Double = 180
    private let owner = UUID()
    private let request: TranscriptionRequest
    private let choice: VoiceEngineChoice
    private let assets: ASRModelAssets
    private let readinessLock = NSLock()
    private var ready = false
    /// 准备阶段（授权/资源/加载）失败的真实原因（readinessLock 保护；协调器经 `preparationFailure` 读取）。
    private var failure: TranscriptionError?
    /// 解码语言提示（`decoderLanguage(for:mode:)`），prepareRuntime 于推理队列写入、schedule 于同队列读取。
    private var language = ""
    private var audio: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var observers: [NSObjectProtocol] = []
    private var tapInstalled = false
    private var job: Job?
    #if os(iOS)
    private var priorSession: AudioSessionCapture.State?
    #endif

    /// 能力诚实：报告模型实际服务的语言，而非请求语言——
    /// 方言请求由普通话基线模型服务时（如 nan-TW → zh），结果 locale
    /// 必须如实回显，不得让面板宣称「已按方言识别」并污染下一次按压。
    /// 语言码回译为标准 locale 标识（zh→zh-Hans-CN 等），避免「尽力识别」
    /// 徽章把普通普通话误标为降级方言（round10 实测误报）。
    var resolvedLocale: String {
        guard let model = ASRModelCatalog.model(for: choice),
              let code = model.languageCode(for: request.localeIdentifier) else { return request.localeIdentifier }
        switch code {
        case "zh": return "zh-Hans-CN"
        case "yue": return "yue-Hant-HK"
        case "en": return "en-US"
        default: return request.localeIdentifier
        }
    }
    /// 准备失败的真实原因：不支持的 locale / 缺件 / 校验或加载失败 = engineUnavailable；
    /// nil = 未失败或为系统麦克风授权拒绝（协调器回落 unauthorized）。round2 A-N5。
    var preparationFailure: TranscriptionError? { readinessLock.withLock { failure } }

    init(request: TranscriptionRequest, choice: VoiceEngineChoice, assets: ASRModelAssets) {
        self.request = request; self.choice = choice; self.assets = assets
    }

    /// 预热（round2 A-N2）：把当前档位模型提前装入推理池，按压时直接进入采集。
    /// 不设 owner、不打断在用会话；池键已匹配则为空操作。返回是否已就位。
    static func preload(choice: VoiceEngineChoice, request: TranscriptionRequest, assets: ASRModelAssets) async -> Bool {
        guard let language = ASRModelCatalog.model(for: choice)?
            .decoderLanguage(for: request.localeIdentifier, mode: request.languageMode) else { return false }
        return await withCheckedContinuation { continuation in
            inferenceQueue.async {
                do {
                    try pool.preload(choice: choice, language: language, assets: assets)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func authorize(_ completion: @escaping @Sendable (Bool) -> Void, isStopped: @escaping @Sendable () -> Bool) {
        guard !isStopped() else { completion(false); return }
        AVCaptureDevice.requestAccess(for: .audio) { [self] granted in
            guard granted, !isStopped() else { completion(false); return }
            Self.inferenceQueue.async { [self] in
                prepareRuntime(completion, isStopped: isStopped, deadline: .now() + 20)
            }
        }
    }

    /// 旧按压收尾回调尚在控制队列时，短暂让出推理队列供其释放租约；不可误判新按压失败。
    private func prepareRuntime(_ completion: @escaping @Sendable (Bool) -> Void,
                                isStopped: @escaping @Sendable () -> Bool, deadline: DispatchTime) {
        guard !isStopped() else { completion(false); return }
        if let active = Self.pool.owner, active != owner, DispatchTime.now() < deadline {
            Self.inferenceQueue.asyncAfter(deadline: .now() + 0.05) { [self] in
                prepareRuntime(completion, isStopped: isStopped, deadline: deadline)
            }
            return
        }
        do {
            // 语言提示按模式产出（round2 A-N1）：单语 = 该模型协议下的语言标记（qwen3 官方名称 /
            // whisper ISO 码），混说 = 空（启用模型自带语种识别）；nil = 该模型不支持此 locale。
            guard let model = ASRModelCatalog.model(for: choice),
                  let language = model.decoderLanguage(for: request.localeIdentifier, mode: request.languageMode) else {
                throw TranscriptionError.engineUnavailable
            }
            try Self.pool.acquire(owner: owner, choice: choice, language: language, assets: assets)
            guard !isStopped() else { Self.pool.release(owner); completion(false); return }
            self.language = language
            readinessLock.withLock { ready = true }
            completion(true)
        } catch {
            // 审查修复：租约/模型加载失败必须如实上报授权失败——旧实现
            // catch 后仍 completion(true)，协调器按已授权继续走采集，
            // startRecognition 再抛 engineUnavailable：诊断阶段（缺件/忙）
            // 与采集阶段错误无法区分，且 UI 从「准备中」误切「采集已开始」。
            // round2 A-N5：失败原因记录为可读状态，协调器不再一律归为 unauthorized。
            readinessLock.withLock {
                ready = false
                failure = (error as? TranscriptionError) ?? .engineUnavailable
            }
            completion(false)
        }
    }

    func startRecognition(id: UUID, onEvent: @escaping @Sendable (SpeechRecognitionEvent) -> Void) throws {
        guard readinessLock.withLock({ ready }) else { throw TranscriptionError.engineUnavailable }
        let next = Job(id: id, onEvent: onEvent)
        job = next
        schedule(next)
    }

    func append(_ audio: CapturedSpeechAudio, to id: UUID) {
        guard let job, job.id == id, !job.cancelled, let converter, let targetFormat else { return }
        let input = audio.pcm
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            job.onEvent(.init(failure: .unavailable)); return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData
            return input
        }
        guard error == nil, status != .error else { job.onEvent(.init(failure: .unavailable)); return }
        guard output.frameLength > 0, let samples = output.floatChannelData?[0] else { return }
        let copied = Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        if job.offer(copied) { schedule(job) }
    }

    func endAudio(id: UUID) {
        guard let job, job.id == id else { return }
        if job.finish() { schedule(job) }
    }

    func cancelRecognition(id: UUID) {
        guard let job, job.id == id else { return }
        job.cancel()
        self.job = nil
    }

    func endSession() {
        let owner = owner
        Self.inferenceQueue.async {
            Self.pool.release(owner)
            let generation = Self.pool.generation
            Self.inferenceQueue.asyncAfter(deadline: .now() + Self.idleEvictionSeconds) {
                if Self.pool.generation == generation { Self.pool.evictWhenIdle() }
            }
        }
    }

    static func unloadWhenIdle() { inferenceQueue.async { pool.evictWhenIdle() } }

    private func schedule(_ job: Job) {
        Self.inferenceQueue.async { [self] in
            guard !job.cancelled, Self.pool.owner == owner, let runtime = Self.pool.runtime else { return }
            do {
                if !job.started {
                    try runtime.begin(language: language, hotwords: request.contextualStrings)
                    job.started = true
                }
                let batch = job.take()
                guard !batch.overflow else { throw TranscriptionError.audioBufferOverflow }
                // 预览让位（round2 A-N3）：收尾已请求或邮箱积压 ≥2s 时跳过预览，把串行队列让给最终解码。
                let text = try runtime.accept(batch.samples, final: batch.final, cancelled: { job.cancelled },
                                              allowPreview: { !job.finishRequested && job.backlogSamples < 2 * 16_000 })
                guard !job.cancelled else { return }
                job.onEvent(.init(text: text, isFinal: batch.final, confidence: 0))
            } catch is CancellationError {
                // 取消只停本代计算；coordinator负责只完成一次，禁止迟到文字。
            } catch {
                if !job.cancelled {
                    job.onEvent(.init(failure: (error as? TranscriptionError) == .audioBufferOverflow ? .bufferOverflow : .unavailable))
                }
            }
        }
    }

    func startCapture(onAudio: @escaping @Sendable (SpeechAudioChunk<CapturedSpeechAudio>) -> Void,
                      onFailure: @escaping @Sendable () -> Void, isStopped: @escaping @Sendable () -> Bool) throws {
        guard !isStopped() else { throw CancellationError() }
        #if os(iOS)
        priorSession = AudioSessionCapture.remember()
        try AudioSessionCapture.activateRecordSession()
        #endif
        let engine = AVAudioEngine()
        audio = engine
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw TranscriptionError.engineUnavailable }
        targetFormat = target; self.converter = converter
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard !isStopped(), buffer.frameLength > 0 else { return }
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let bytes = source.reduce(0) { $0 + Int($1.mDataByteSize) }
            guard bytes <= SpeechSessionLimits().maximumBufferedBytes,
                  let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { onFailure(); return }
            copy.frameLength = buffer.frameLength
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in source.indices {
                guard destination.indices.contains(index), source[index].mDataByteSize == destination[index].mDataByteSize,
                      let from = source[index].mData, let to = destination[index].mData else { onFailure(); return }
                memcpy(to, from, Int(source[index].mDataByteSize))
            }
            onAudio(.init(buffer: .init(pcm: copy), duration: Double(copy.frameLength) / copy.format.sampleRate, byteCount: bytes))
        }
        tapInstalled = true
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil) { _ in onFailure() })
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: nil) { _ in onFailure() })
        #endif
        guard !isStopped() else { throw CancellationError() }
        engine.prepare(); try engine.start()
        if isStopped() { throw CancellationError() }
    }

    func stopCapture() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        if let audio { audio.stop(); if tapInstalled { audio.inputNode.removeTap(onBus: 0) } }
        audio = nil; tapInstalled = false
        #if os(iOS)
        if let priorSession { AudioSessionCapture.restore(priorSession); self.priorSession = nil }
        #endif
    }

    private final class RuntimePool: @unchecked Sendable {
        var owner: UUID?
        var runtime: SherpaASRRuntime?
        private var key: String?
        var generation: UInt64 = 0
        private var evictOnRelease = false
        private var assetLease: ASRModelAssets.Lease?

        /// 池键 = 档位 + whisper 语言 + 资产身份。qwen3 的语言/热词均为 per-stream 选项、由
        /// `SherpaASRRuntime.begin(language:hotwords:)` 每段显式装配（含空值），不会沿用上一会话
        /// （owner round10 错乱根因已由显式装配消除）——因此不入键：预热与按压在单语/混说、
        /// 普通话/粤语间切换或药箱变动时都不再触发整模重载（round2 A-N2/A-N7）。
        /// whisper 的语言写入 config，仍属运行时身份。
        private static func key(choice: VoiceEngineChoice, language: String, assets: ASRModelAssets) -> String {
            choice.rawValue + ":" + (choice == .whisper ? language : "") + ":" + assets.identity
        }

        private func load(choice: VoiceEngineChoice, language: String, assets: ASRModelAssets, key nextKey: String) throws {
            runtime = nil; key = nil; assetLease = nil
            let lease = assets.acquireLease()
            let validated = try assets.validate(choice)
            runtime = try SherpaASRRuntime(choice: choice, language: language, assets: validated)
            assetLease = lease
            key = nextKey
        }

        func acquire(owner: UUID, choice: VoiceEngineChoice, language: String, assets: ASRModelAssets) throws {
            try assets.checkPackageAuthorization()
            guard self.owner == nil || self.owner == owner else { throw TranscriptionError.engineUnavailable }
            let nextKey = Self.key(choice: choice, language: language, assets: assets)
            if key != nextKey || runtime == nil {
                try load(choice: choice, language: language, assets: assets, key: nextKey)
            }
            self.owner = owner
            generation &+= 1
            evictOnRelease = false
        }

        /// 预热：无 owner 接管；有会话在用不打断；键已匹配则只刷新代次（使挂起的闲置驱逐失效）。
        func preload(choice: VoiceEngineChoice, language: String, assets: ASRModelAssets) throws {
            try assets.checkPackageAuthorization()
            guard owner == nil else { return }
            let nextKey = Self.key(choice: choice, language: language, assets: assets)
            if key != nextKey || runtime == nil {
                try load(choice: choice, language: language, assets: assets, key: nextKey)
            }
            // 代次推进：endSession 排下的 idleEvictionSeconds 驱逐按代次判定，预热后不得把刚装入的
            // 模型在用户按压前驱逐。
            generation &+= 1
            evictOnRelease = false
        }
        func release(_ owner: UUID) {
            if self.owner == owner {
                self.owner = nil; generation &+= 1
                if evictOnRelease { runtime = nil; key = nil; assetLease = nil }
            }
        }
        func evictWhenIdle() {
            evictOnRelease = true
            if owner == nil { runtime = nil; key = nil; assetLease = nil; generation &+= 1 }
        }
    }

    private final class Job: @unchecked Sendable {
        let id: UUID
        let onEvent: @Sendable (SpeechRecognitionEvent) -> Void
        var started = false // inferenceQueue only
        private let lock = NSLock()
        private var audio: [Float] = []
        private var ended = false
        private var stopped = false
        private var scheduled = true
        private var overflow = false
        /// 邮箱上限 30s@16k：5s 邮箱在预览解码占队时溢出即 .bufferOverflow 终止会话（round2 A-N3）。
        private static let capacity = 480_000
        var cancelled: Bool { lock.withLock { stopped } }
        /// 尚未被 take 的积压样本数（预览让位判据）。
        var backlogSamples: Int { lock.withLock { audio.count } }
        /// 收尾已请求（final 待处理，预览一律让位）。
        var finishRequested: Bool { lock.withLock { ended } }
        init(id: UUID, onEvent: @escaping @Sendable (SpeechRecognitionEvent) -> Void) { self.id = id; self.onEvent = onEvent }
        func offer(_ samples: [Float]) -> Bool {
            lock.withLock {
                guard !stopped, !ended else { return false }
                if samples.count > Self.capacity - audio.count { overflow = true }
                else if !overflow { audio.append(contentsOf: samples) }
                guard !scheduled else { return false }
                scheduled = true; return true
            }
        }
        func finish() -> Bool {
            lock.withLock { ended = true; guard !stopped, !scheduled else { return false }; scheduled = true; return true }
        }
        func take() -> (samples: [Float], final: Bool, overflow: Bool) {
            lock.withLock {
                defer { audio = []; scheduled = false }
                return (audio, ended, overflow)
            }
        }
        func cancel() { lock.withLock { stopped = true; audio = [] } }
    }
}
#endif
