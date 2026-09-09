#if os(iOS) || os(macOS)
import Foundation
import AVFoundation
import Speech
import Domain
import Protocols

/// ADR-023 基线轨：端侧 SFSpeechRecognizer（`requiresOnDeviceRecognition=true`，隐私红线 BR-002 延伸）。
///
/// 升级轨（iOS 26+）的 `SpeechAnalyzer`/`SpeechTranscriber`（长音频免分段）在同 `TranscriptionEngine`
/// 协议下替换本类——上层零感知降级。
///
/// **V3.61 连续会话（FR17.1 停顿丢字修正）**：一次 `transcribe` = 一次按住说话；单音频 tap
/// 持续到 `endAudio()`（松手），识别请求多轮（`ContinuousRecognition`）——静音端点/~60s 上限的
/// isFinal 只提交一段并立即换新请求，`maxSegmentSeconds - 5` 秒主动换段；返回各段拼接。
/// **FR17.15 混说词表**：`request.contextualStrings` 注入 `SFSpeechRecognitionRequest.contextualStrings`
/// （≤100，Apple 建议上限）。
///
/// 评审修正（Apple SDK 首次真实编译暴露，5WHY 同 CaptureQuality——Apple 轨代码此前
/// 无任何编译门禁）：
/// - `SFSpeechRecognizer(locale:)` 是 failable init，locale 在这里注入（request 无 locale
///   属性）；`supportsOnDeviceRecognition` 是**实例**属性而非类属性；
/// - 识别器必须被**强持有**到识别结束（Apple 文档要求）。本实现中 recognizer/recog/audio
///   均为 transcribe 局部量，被识别任务回调闭包捕获——task 存活期间识别器必存活，
///   函数返回（isFinal/error）后随闭包释放，天然满足强持有语义；
/// - 置信度位于 `bestTranscription.segments[].confidence`（SFTranscription 无 confidence）；
/// - 清理（audio.stop/removeTap）在错误与成功路径统一执行（do/catch + 路径内清理），
///   修复原实现抛错后 AVAudioEngine 持续采音泄漏。
///
/// 注：识别回调不捕获 actor self——多轮请求编排下沉到 `ContinuousRecognition`（NSLock 保护的
/// final class），actor 只持有会话引用供 `endAudio()` 收尾；识别器由该对象强持有到会话结束。
public actor SFSpeechTranscriber: TranscriptionEngine {
    public nonisolated let capability: TranscriptionCapability

    /// 活跃会话计数：软停（VoiceDictationModel.stop）不取消引擎——旧会话
    /// 仍等静音端点、其 defer 才复位音频会话。快速重录时新旧两个 transcribe
    /// 并发，旧会话先结束若无条件 setActive(false) 会把新会话已激活的共享
    /// 会话一并关掉，新录音静默收不到缓冲。计数归零才复位。
    private var activeSessions = 0
    /// 当前活跃连续识别会话（软停 endAudio 收尾；仅最新会话）
    private var activeSession: ContinuousRecognition?

    public init() {
        // FR17.15 六语种能力**运行时探测**（tech §5.13「不硬编码」）：
        // supportedLocales ∩ 端侧识别——此前 .baseline() 恒 {zh-Hans-CN}，
        // 选择粤语/英语后全部回落普通话识别（注释声称「用户选择的输入语言
        // 必须生效」与实现矛盾，假能力呈现）
        self.capability = Self.probeCapability()
    }

    /// 探测实际可用的端侧识别 locale 集；探测失败回落 zh-Hans-CN（绝不
    /// 声称支持未探测的语种）
    private static func probeCapability() -> TranscriptionCapability {
        let probed = SFSpeechRecognizer.supportedLocales().filter { locale in
            SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
        }.map(\.identifier)
        let locales = probed.isEmpty ? ["zh-Hans-CN"] : probed
        return .baseline(locales: Set(locales))
    }

    /// 软停提示（用户松手）：置收尾标记并结束当前请求——下一段 isFinal 到达后会话返回。
    /// 不再换段；已提交段全部保留（V3.61 停顿丢字修正）。
    public func endAudio() async {
        activeSession?.finish()
    }

    /// 连续识别会话（FR17.1 V3.61）：**单音频引擎 tap 持续到松手，识别请求多轮**——
    /// 静音端点/基线轨 ~60s 上限产生的 isFinal 只是「提交一段」，随即创建新请求继续
    /// 消费同一 tap 的缓冲；`maxSegmentSeconds - 5` 秒时主动换段（`TranscriptionSegmentation`
    /// 同口径）；松手（endAudio）→ 当前请求收尾 → 返回各段拼接。子段 noSpeech 类错误在
    /// 已有文本时不抛（继续或收尾），只有整段会话零文本才按错误/空结果返回。
    public func transcribe(_ request: TranscriptionRequest,
                          onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
        let resolvedLocale = capability.availableLocales.contains(request.localeIdentifier)
            ? request.localeIdentifier : TranscriptionSegmentation.fallbackLocale
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: resolvedLocale)) else {
            throw TranscriptionError.engineUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.engineUnavailable
        }
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard auth == .authorized else { throw TranscriptionError.unauthorized }

        let audio = AVAudioEngine()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            throw TranscriptionError.engineUnavailable
        }
        activeSessions += 1
        defer {
            activeSessions -= 1
            // 仅当无其他活跃转写会话时复位共享音频会话——软停后的旧会话
            // 不得关掉新会话已激活的录音输入
            if activeSessions == 0 {
                try? session.setActive(false, options: [.notifyOthersOnDeactivation])   // try?-ok: 会话复位失败不掩盖主结果
            }
        }
        #endif

        // FR17.15 混说词表注入（V3.61）：SFSpeechRecognitionRequest.contextualStrings 自 iOS 10
        // 可用（此前注释误称 request 无此属性）；主语言识别 + 高频混说词/已确认药名偏置
        let continuous = ContinuousRecognition(recognizer: recognizer, capability: capability,
                                               contextualStrings: Array(request.contextualStrings.prefix(100)),
                                               onPartial: onPartial)
        activeSession = continuous
        defer { if activeSession === continuous { activeSession = nil } }

        let inputNode = audio.inputNode
        let fmt = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [continuous] buffer, _ in
            continuous.append(buffer)
        }
        audio.prepare()
        do {
            try audio.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }

        let segments: [String]
        let confidence: Double
        do {
            (segments, confidence) = try await continuous.run()
        } catch {
            audio.stop()
            inputNode.removeTap(onBus: 0)
            throw error
        }
        audio.stop()
        inputNode.removeTap(onBus: 0)
        return TranscriptionResult(text: segments.joined(separator: " "), confidence: confidence,
                                   resolvedLocale: resolvedLocale, segmented: segments.count > 1,
                                   segments: segments)
    }
}

/// 一次按住说话的多轮识别请求编排（`SFSpeechTranscriber` 内部）。
/// 线程模型：tap 回调线程 `append`；识别回调线程 `handle`；NSLock 保护请求/累加器/状态。
/// 强持有 recognizer（Apple 要求识别期间存活）。
final class ContinuousRecognition: @unchecked Sendable {
    private let lock = NSLock()
    private let recognizer: SFSpeechRecognizer
    private let capability: TranscriptionCapability
    private let contextualStrings: [String]
    private let onPartial: (@Sendable (String) -> Void)?
    private var current: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?
    private var accumulator = TranscriptSessionAccumulator()
    private var confidences: [Double] = []
    private var finishing = false
    private var settled = false
    private var continuation: CheckedContinuation<([String], Double), Error>?
    private var segmentStart = Date()
    private var rotationTimer: Task<Void, Never>?

    init(recognizer: SFSpeechRecognizer, capability: TranscriptionCapability,
         contextualStrings: [String], onPartial: (@Sendable (String) -> Void)?) {
        self.recognizer = recognizer
        self.capability = capability
        self.contextualStrings = contextualStrings
        self.onPartial = onPartial
        self.current = Self.makeRequest(contextualStrings)
    }

    private static func makeRequest(_ contextualStrings: [String]) -> SFSpeechAudioBufferRecognitionRequest {
        let recog = SFSpeechAudioBufferRecognitionRequest()
        recog.requiresOnDeviceRecognition = true
        recog.shouldReportPartialResults = true
        recog.taskHint = .dictation
        if !contextualStrings.isEmpty { recog.contextualStrings = contextualStrings }
        return recog
    }

    /// tap 回调：喂当前请求（换段瞬间的缓冲归新请求——边界词裁剪是固有代价）
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let recog = current; lock.unlock()
        recog.append(buffer)
    }

    /// 松手：不再换段；当前请求 endAudio，等其 isFinal 收尾
    func finish() {
        lock.lock()
        finishing = true
        let recog = current
        lock.unlock()
        recog.endAudio()
    }

    /// 运行至松手后最后一段 isFinal；返回各段与平均置信度
    func run() async throws -> ([String], Double) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<([String], Double), Error>) in
            lock.lock()
            continuation = cont
            lock.unlock()
            startSegment()
        }
    }

    private func startSegment() {
        lock.lock()
        segmentStart = Date()
        let recog = current
        rotationTimer?.cancel()
        // 主动换段：基线轨在上限前 5s 换请求（升级轨 shouldRotate 恒 false）
        let rotateAfter = Double(max(5, capability.maxSegmentSeconds - 5))
        if !capability.supportsLongForm {
            rotationTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(rotateAfter * 1_000_000_000))   // try?-ok: 计时取消即停
                guard !Task.isCancelled else { return }
                self?.rotateIfRunning(expected: recog)
            }
        }
        lock.unlock()
        let started = recognizer.recognitionTask(with: recog) { [weak self] result, error in
            self?.handle(result: result, error: error, for: recog)
        }
        lock.lock(); task = started; lock.unlock()
    }

    /// 计时换段：只对仍是当前请求的段生效（避免 isFinal 已换段后重复换）
    private func rotateIfRunning(expected: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        guard !finishing, current === expected else { lock.unlock(); return }
        lock.unlock()
        expected.endAudio()   // 触发该段 isFinal → handle 中提交并换段
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?,
                        for recog: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        guard !settled, current === recog else { lock.unlock(); return }
        if let error {
            // 子段错误（如静音段 noSpeech）：已有文本则继续/收尾，不整体失败
            if finishing {
                settleLocked(error: accumulator.committed.isEmpty && accumulator.partial.isEmpty ? error : nil)
            } else if accumulator.committed.isEmpty && accumulator.partial.isEmpty {
                settleLocked(error: error)
            } else {
                rotateLocked()
            }
            lock.unlock()
            return
        }
        guard let result else { lock.unlock(); return }
        let text = result.bestTranscription.formattedString
        if result.isFinal {
            let segs = result.bestTranscription.segments
            if !segs.isEmpty {
                confidences.append(Double(segs.map(\.confidence).reduce(0, +) / Float(segs.count)))
            }
            accumulator.commit(text)
            if finishing {
                settleLocked(error: nil)
            } else {
                rotateLocked()
            }
            lock.unlock()
            return
        }
        accumulator.updatePartial(text)
        let display = accumulator.displayText
        lock.unlock()
        onPartial?(display)
    }

    /// 换段（持锁）：新请求接管 tap；在锁外启动识别任务
    private func rotateLocked() {
        current = Self.makeRequest(contextualStrings)
        let display = accumulator.displayText
        DispatchQueue.global().async { [weak self] in
            self?.startSegment()
            self?.onPartial?(display)
        }
    }

    private func settleLocked(error: Error?) {
        settled = true
        rotationTimer?.cancel()
        let segments = accumulator.finish()
        let confidence = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
        let cont = continuation
        continuation = nil
        if let error, segments.isEmpty {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: (segments, confidence))
        }
    }
}
#endif
