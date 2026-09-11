import Foundation
import Dispatch
import Domain
import Protocols

// The portable coordinator is exercised with a driver replacing only the native SDK boundaries.
struct SpeechSessionLimits: Sendable {
    var rotationInterval: TimeInterval = 55
    var finalizationTimeout: TimeInterval = 2
    var restartDelay: TimeInterval = 0.25
    var maximumBufferedSeconds: TimeInterval = 5
    var maximumBufferedBytes = 4 * 1024 * 1024
    var maximumBufferedChunks = 1024
    var maximumRecoveryAttempts = 2
}

struct SpeechAudioChunk<Audio: Sendable>: Sendable {
    let buffer: Audio
    let duration: TimeInterval
    let byteCount: Int
}

enum SpeechRecognitionFailure: Sendable, Equatable { case noSpeech, unauthorized, unavailable, bufferOverflow }

struct SpeechRecognitionEvent: Sendable {
    var text: String? = nil
    var isFinal = false
    var confidence: Double = 0
    var failure: SpeechRecognitionFailure? = nil
}

/// All methods except asynchronous authorization/capture callbacks run on the speech control queue.
protocol SpeechSessionDriver: AnyObject, Sendable {
    associatedtype Audio: Sendable
    var resolvedLocale: String { get }
    func authorize(_ completion: @escaping @Sendable (Bool) -> Void,
                   isStopped: @escaping @Sendable () -> Bool)
    func startCapture(onAudio: @escaping @Sendable (SpeechAudioChunk<Audio>) -> Void,
                      onFailure: @escaping @Sendable () -> Void,
                      isStopped: @escaping @Sendable () -> Bool) throws
    func stopCapture()
    func startRecognition(id: UUID, onEvent: @escaping @Sendable (SpeechRecognitionEvent) -> Void) throws
    func append(_ audio: Audio, to id: UUID)
    func endAudio(id: UUID)
    func cancelRecognition(id: UUID)
    func endSession()
}

extension SpeechSessionDriver { func endSession() {} }

private final class SpeechStopSignal: @unchecked Sendable {
    enum Intent: Sendable, Equatable { case running, finish, cancel }
    private let lock = NSLock()
    private var value: Intent = .running
    var intent: Intent { lock.lock(); defer { lock.unlock() }; return value }
    func finish() { lock.lock(); if value == .running { value = .finish }; lock.unlock() }
    func cancel() { lock.lock(); value = .cancel; lock.unlock() }
}

/// Bounded tap mailbox: the real-time callback never waits on the control queue or audio shutdown.
private final class SpeechAudioMailbox<Audio: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: SpeechSessionLimits
    private var chunks: [SpeechAudioChunk<Audio>] = []
    private var seconds: TimeInterval = 0
    private var bytes = 0
    private var scheduled = false
    private var overflow = false
    private var closed = false

    init(limits: SpeechSessionLimits) { self.limits = limits }

    func offer(_ chunk: SpeechAudioChunk<Audio>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        if chunk.duration <= 0 || !chunk.duration.isFinite || chunk.byteCount < 0
            || seconds + chunk.duration > limits.maximumBufferedSeconds
            || chunk.byteCount > limits.maximumBufferedBytes - bytes
            || chunks.count >= limits.maximumBufferedChunks {
            overflow = true
        } else if !overflow {
            chunks.append(chunk)
            seconds += chunk.duration
            bytes += chunk.byteCount
        }
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func take(closing: Bool = false) -> (chunks: [SpeechAudioChunk<Audio>], overflow: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if closing { closed = true }
        let result = (chunks, overflow)
        chunks.removeAll(keepingCapacity: !closing)
        seconds = 0
        bytes = 0
        overflow = false
        scheduled = false
        return result
    }
}

/// Queue confinement protects session ownership, SDK calls, timer transitions and output order.
final class SpeechSessionCoordinator<Driver: SpeechSessionDriver>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UUID>()
    private let queueID = UUID()
    private let limits: SpeechSessionLimits
    private let makeDriver: @Sendable (TranscriptionRequest) -> Driver
    /// Only stop intents cross the queue boundary; no SDK calls or continuations run under this lock.
    private let signalLock = NSLock()
    private var signals: [UUID: SpeechStopSignal] = [:]
    private var sessions: [UUID: ContinuousRecognition<Driver>] = [:]
    private var captureOwner: UUID?
    private var retired: [UUID] = []

    init(queue: DispatchQueue = DispatchQueue(label: "com.vitaliber.speech", qos: .userInitiated),
         limits: SpeechSessionLimits = SpeechSessionLimits(),
         makeDriver: @escaping @Sendable (TranscriptionRequest) -> Driver) {
        self.queue = queue
        self.limits = limits
        self.makeDriver = makeDriver
        queue.setSpecific(key: queueKey, value: queueID)
    }

    func transcribe(_ request: TranscriptionRequest,
                    onPartial: (@Sendable (String) -> Void)?,
                    onCaptureStarted: (@Sendable () -> Void)? = nil) async throws -> TranscriptionResult {
        let signal = signal(for: request.sessionID)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    let id = request.sessionID
                    guard self.sessions[id] == nil, !self.retired.contains(id) else {
                        if self.retired.contains(id) { self.removeSignal(id) }
                        continuation.resume(throwing: TranscriptionError.engineUnavailable)
                        return
                    }
                    if signal.intent != .running {
                        self.retire(id)
                        if signal.intent == .cancel {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(returning: TranscriptionResult(text: "", confidence: 0,
                                                                               resolvedLocale: "", segmented: false))
                        }
                        return
                    }
                    // Supersession closes capture synchronously; its recognizer may keep draining.
                    if let owner = self.captureOwner { self.sessions[owner]?.finish() }
                    let session = ContinuousRecognition(
                        driver: self.makeDriver(request), queue: self.queue,
                        queueKey: self.queueKey, queueID: self.queueID, limits: self.limits,
                        signal: signal, onPartial: onPartial, onCaptureStarted: onCaptureStarted, continuation: continuation,
                        onCaptureStopped: { [weak self] in
                            if self?.captureOwner == id { self?.captureOwner = nil }
                        }, onSettled: { [weak self] in
                            self?.sessions[id] = nil
                            self?.retire(id)
                        })
                    self.sessions[id] = session
                    self.captureOwner = id
                    session.start()
                }
            }
        } onCancel: {
            // The latch also prevents setup from starting hardware before this queued cancellation runs.
            signal.cancel()
            self.queue.async { self.stop(request.sessionID, intent: .cancel) }
        }
    }

    func finish(sessionID: UUID) async {
        signal(for: sessionID).finish()
        await withCheckedContinuation { continuation in
            queue.async {
                self.stop(sessionID, intent: .finish)
                continuation.resume()
            }
        }
    }

    func cancel(sessionID: UUID) async {
        signal(for: sessionID).cancel()
        await withCheckedContinuation { continuation in
            queue.async {
                self.stop(sessionID, intent: .cancel)
                continuation.resume()
            }
        }
    }

    func discardSession(sessionID: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async {
                if let session = self.sessions[sessionID] { session.cancel() }
                else { self.retire(sessionID) }
                continuation.resume()
            }
        }
    }

    func finishCapture() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if let owner = self.captureOwner { self.sessions[owner]?.finish() }
                continuation.resume()
            }
        }
    }

    private func stop(_ id: UUID, intent: SpeechStopSignal.Intent) {
        if let session = sessions[id] {
            if intent == .cancel { session.cancel() } else { session.finish() }
        } else if retired.contains(id) {
            removeSignal(id)
        }
    }

    private func signal(for id: UUID) -> SpeechStopSignal {
        signalLock.lock()
        defer { signalLock.unlock() }
        if let existing = signals[id] { return existing }
        let signal = SpeechStopSignal()
        signals[id] = signal
        return signal
    }

    private func removeSignal(_ id: UUID) {
        signalLock.lock()
        signals[id] = nil
        signalLock.unlock()
    }

    private func retire(_ id: UUID) {
        removeSignal(id)
        retired.append(id)
        if retired.count > 256 { retired.removeFirst(retired.count - 256) }
    }
}

private final class ContinuousRecognition<Driver: SpeechSessionDriver>: @unchecked Sendable {
    private let driver: Driver
    private let queue: DispatchQueue
    private let queueKey: DispatchSpecificKey<UUID>
    private let queueID: UUID
    private let limits: SpeechSessionLimits
    private let signal: SpeechStopSignal
    private let mailbox: SpeechAudioMailbox<Driver.Audio>
    private let onPartial: (@Sendable (String) -> Void)?
    private let onCaptureStarted: (@Sendable () -> Void)?
    private let onCaptureStopped: () -> Void
    private let onSettled: () -> Void
    private var continuation: CheckedContinuation<TranscriptionResult, Error>?
    private var accumulator = TranscriptSessionAccumulator()
    private var current: UUID?
    private var authorizationPending = true
    private var waitingForFinal = false
    private var finishing = false
    private var settled = false
    private var handoff: [SpeechAudioChunk<Driver.Audio>] = []
    private var handoffSeconds: TimeInterval = 0
    private var handoffBytes = 0
    private var rotationTimer: DispatchWorkItem?
    private var drainTimer: DispatchWorkItem?
    private var restartTimer: DispatchWorkItem?
    private var recoveryAttempts = 0
    private var completion: TranscriptionCompletion = .final
    private var confidences: [Double] = []
    private var lastPublished = ""

    init(driver: Driver, queue: DispatchQueue, queueKey: DispatchSpecificKey<UUID>, queueID: UUID,
         limits: SpeechSessionLimits, signal: SpeechStopSignal,
          onPartial: (@Sendable (String) -> Void)?,
          onCaptureStarted: (@Sendable () -> Void)?,
         continuation: CheckedContinuation<TranscriptionResult, Error>,
         onCaptureStopped: @escaping () -> Void, onSettled: @escaping () -> Void) {
        self.driver = driver
        self.queue = queue
        self.queueKey = queueKey
        self.queueID = queueID
        self.limits = limits
        self.signal = signal
        self.mailbox = SpeechAudioMailbox(limits: limits)
        self.onPartial = onPartial
        self.onCaptureStarted = onCaptureStarted
        self.continuation = continuation
        self.onCaptureStopped = onCaptureStopped
        self.onSettled = onSettled
    }

    private func perform(_ action: @escaping @Sendable (ContinuousRecognition) -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == queueID {
            action(self)
        } else {
            queue.async { action(self) }
        }
    }

    func start() {
        guard !settled else { return }
        let signal = signal
        driver.authorize({ [weak self] authorized in
            self?.perform { session in
                guard !session.settled, session.authorizationPending else { return }
                session.authorizationPending = false
                if signal.intent == .cancel { session.cancel(); return }
                if signal.intent == .finish { session.finish(); return }
                guard authorized else { session.settle(error: TranscriptionError.unauthorized); return }
                session.startSegment()
                guard !session.settled, !session.finishing, signal.intent == .running else { return }
                do {
                    try session.driver.startCapture(onAudio: { [weak session] chunk in
                        guard let session, session.mailbox.offer(chunk) else { return }
                        session.queue.async { session.consumeMailbox() }
                    }, onFailure: { [weak session] in
                        guard let session else { return }
                        // A configuration notification may be synchronous inside AVAudioEngine.start().
                        session.queue.async {
                            guard !session.settled else { return }
                            session.completion = .interrupted
                            session.settle(error: TranscriptionError.engineUnavailable)
                        }
                    }, isStopped: { signal.intent != .running })
                    if signal.intent == .cancel { session.cancel() }
                    else if signal.intent == .finish { session.finish() }
                    else { session.onCaptureStarted?() }
                } catch is CancellationError {
                    if signal.intent == .finish { session.finish() } else { session.cancel() }
                } catch {
                    session.completion = .interrupted
                    session.settle(error: error)
                }
            }
        }, isStopped: { signal.intent != .running })
    }

    func finish() {
        guard !settled, !finishing else { return }
        signal.finish()
        finishing = true
        rotationTimer?.cancel()
        rotationTimer = nil
        restartTimer?.cancel()
        restartTimer = nil
        driver.stopCapture()
        onCaptureStopped()
        consumeMailbox(closing: true)
        guard !settled else { return }
        if current != nil {
            endCurrentSegment()
        } else if !handoff.isEmpty {
            startSegment()
        } else {
            settle()
        }
    }

    func cancel() {
        signal.cancel()
        settle(error: CancellationError())
    }

    private func consumeMailbox(closing: Bool = false) {
        let batch = mailbox.take(closing: closing)
        guard !settled else { return }
        if signal.intent == .cancel { cancel(); return }
        if batch.overflow {
            completion = .bufferOverflow
            settle(error: TranscriptionError.audioBufferOverflow)
            return
        }
        for chunk in batch.chunks {
            guard !settled else { return }
            if signal.intent == .cancel { cancel(); return }
            if signal.intent == .finish, !finishing { driver.stopCapture() }
            if let current, !waitingForFinal {
                driver.append(chunk.buffer, to: current)
            } else {
                guard handoffSeconds + chunk.duration <= limits.maximumBufferedSeconds,
                      chunk.byteCount <= limits.maximumBufferedBytes - handoffBytes,
                      handoff.count < limits.maximumBufferedChunks else {
                    completion = .bufferOverflow
                    settle(error: TranscriptionError.audioBufferOverflow)
                    return
                }
                handoff.append(chunk)
                handoffSeconds += chunk.duration
                handoffBytes += chunk.byteCount
            }
        }
    }

    private func startSegment() {
        guard !settled, current == nil else { return }
        if signal.intent == .cancel { cancel(); return }
        let id = UUID()
        current = id
        waitingForFinal = false
        do {
            try driver.startRecognition(id: id) { [weak self] event in
                self?.perform { $0.handle(event, segment: id) }
            }
        } catch {
            completion = .interrupted
            settle(error: error)
            return
        }
        guard !settled, current == id else { return }
        let replay = handoff
        handoff.removeAll(keepingCapacity: true)
        handoffSeconds = 0
        handoffBytes = 0
        for chunk in replay {
            if signal.intent == .cancel { cancel(); return }
            if signal.intent == .finish, !finishing { driver.stopCapture() }
            driver.append(chunk.buffer, to: id)
        }
        if finishing {
            endCurrentSegment()
        } else {
            let timer = DispatchWorkItem { [weak self] in
                guard let self, !self.settled, !self.finishing, self.current == id else { return }
                self.endCurrentSegment()
            }
            rotationTimer = timer
            queue.asyncAfter(deadline: .now() + limits.rotationInterval, execute: timer)
        }
    }

    private func endCurrentSegment() {
        guard !settled, let id = current, !waitingForFinal else { return }
        // From this transition onward, all captured buffers go into the bounded handoff queue.
        waitingForFinal = true
        rotationTimer?.cancel()
        rotationTimer = nil
        driver.endAudio(id: id)
        guard !settled, current == id, waitingForFinal else { return }
        let timer = DispatchWorkItem { [weak self] in
            guard let self, !self.settled, self.current == id, self.waitingForFinal else { return }
            self.completion = .timedOut
            self.recoveryAttempts += 1
            if !self.finishing, self.recoveryAttempts > self.limits.maximumRecoveryAttempts {
                self.settle(error: TranscriptionError.timedOut)
            } else {
                self.completeSegment(text: nil, confidence: nil, restartDelay: self.limits.restartDelay)
            }
        }
        drainTimer = timer
        queue.asyncAfter(deadline: .now() + limits.finalizationTimeout, execute: timer)
    }

    private func handle(_ event: SpeechRecognitionEvent, segment id: UUID) {
        guard !settled, current == id else { return }
        if signal.intent == .cancel { cancel(); return }
        if let text = event.text { accumulator.updatePartial(text) }
        if let failure = event.failure {
            switch failure {
            case .noSpeech:
                // Silence is an endpoint, not a fatal retry. Rate-limit new requests while keeping capture alive.
                completeSegment(text: event.isFinal ? event.text : nil, confidence: nil,
                                restartDelay: limits.restartDelay)
            case .unauthorized, .unavailable:
                completion = .interrupted
                settle(error: failure == .unauthorized ? TranscriptionError.unauthorized : .engineUnavailable)
            case .bufferOverflow:
                completion = .bufferOverflow
                settle(error: TranscriptionError.audioBufferOverflow)
            }
        } else if event.isFinal {
            let emptyFinal = event.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            completeSegment(text: event.text, confidence: event.confidence,
                            restartDelay: emptyFinal ? limits.restartDelay : 0)
        } else {
            if let text = event.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recoveryAttempts = 0
            }
            publish()
        }
    }

    private func completeSegment(text: String?, confidence: Double?, restartDelay: TimeInterval) {
        guard let id = current else { return }
        let final = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if final.isEmpty || confidence == nil {
            if !accumulator.partial.isEmpty, completion == .final { completion = .partial }
        } else if let confidence {
            confidences.append(confidence)
            recoveryAttempts = 0
        }
        accumulator.commit(final)
        rotationTimer?.cancel()
        drainTimer?.cancel()
        rotationTimer = nil
        drainTimer = nil
        current = nil
        waitingForFinal = false
        driver.cancelRecognition(id: id)
        publish() // Publish the committed boundary before starting a request that can publish newer text.
        consumeMailbox()
        guard !settled else { return }
        if finishing {
            if handoff.isEmpty { settle() } else { startSegment() }
        } else if restartDelay > 0 {
            let timer = DispatchWorkItem { [weak self] in
                guard let self, !self.settled, !self.finishing, self.current == nil else { return }
                self.restartTimer = nil
                self.startSegment()
            }
            restartTimer = timer
            queue.asyncAfter(deadline: .now() + restartDelay, execute: timer)
        } else {
            startSegment()
        }
    }

    private func publish() {
        let display = accumulator.displayText
        guard display != lastPublished else { return }
        lastPublished = display
        onPartial?(display)
    }

    private func settle(error: Error? = nil) {
        guard !settled else { return }
        settled = true
        signal.finish()
        driver.stopCapture()
        onCaptureStopped()
        _ = mailbox.take(closing: true)
        rotationTimer?.cancel()
        drainTimer?.cancel()
        restartTimer?.cancel()
        rotationTimer = nil
        drainTimer = nil
        restartTimer = nil
        if let current { driver.cancelRecognition(id: current) }
        driver.endSession()
        current = nil
        handoff.removeAll()
        let segments = accumulator.finish()
        let continuation = continuation
        self.continuation = nil
        onSettled()
        // No mutex is held across SDK cancellation, consumer callbacks or continuation resumption.
        if error is CancellationError || signal.intent == .cancel {
            continuation?.resume(throwing: CancellationError())
        } else if let error, segments.isEmpty {
            continuation?.resume(throwing: error)
        } else {
            publish()
            let confidence = completion == .final && !confidences.isEmpty
                ? confidences.reduce(0, +) / Double(confidences.count) : 0
            continuation?.resume(returning: TranscriptionResult(
                text: segments.joined(separator: " "), confidence: confidence,
                resolvedLocale: driver.resolvedLocale, segmented: segments.count > 1,
                segments: segments, completion: completion))
        }
    }
}

#if os(iOS) || os(macOS)
import AVFoundation
import Speech

/// ADR-023 baseline: on-device recognition, one capture owner, no permanent audio files.
public actor SFSpeechTranscriber: TranscriptionCaptureReporting {
    public nonisolated let capability: TranscriptionCapability
    private nonisolated let coordinator: SpeechSessionCoordinator<NativeSpeechSessionDriver>

    public init() {
        capability = Self.probeCapability()
        let queue = DispatchQueue(label: "com.vitaliber.speech.native", qos: .userInitiated)
        coordinator = SpeechSessionCoordinator(queue: queue) { request in
            NativeSpeechSessionDriver(request: request, queue: queue)
        }
    }

    fileprivate static func probeCapability() -> TranscriptionCapability {
        var locales = Set<String>()
        for locale in SFSpeechRecognizer.supportedLocales() {
            guard let recognizer = SFSpeechRecognizer(locale: locale),
                  recognizer.supportsOnDeviceRecognition, recognizer.isAvailable,
                  TranscriptionLocale.normalizedIdentifier(recognizer.locale.identifier)
                    == TranscriptionLocale.normalizedIdentifier(locale.identifier) else { continue }
            locales.insert(recognizer.locale.identifier)
        }
        return .baseline(locales: locales)
    }

    public nonisolated func currentCapability() async -> TranscriptionCapability { Self.probeCapability() }

    public nonisolated func transcribe(_ request: TranscriptionRequest,
                                        onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
        try await coordinator.transcribe(request, onPartial: onPartial)
    }

    public nonisolated func transcribe(_ request: TranscriptionRequest, onPartial: (@Sendable (String) -> Void)?,
                                       onCaptureStarted: @escaping @Sendable () -> Void) async throws -> TranscriptionResult {
        var result = try await coordinator.transcribe(request, onPartial: onPartial, onCaptureStarted: onCaptureStarted)
        result.engineID = VoiceEngineChoice.classic.rawValue
        return result
    }

    public nonisolated func finish(sessionID: UUID) async { await coordinator.finish(sessionID: sessionID) }
    public nonisolated func cancel(sessionID: UUID) async { await coordinator.cancel(sessionID: sessionID) }
    public nonisolated func discardSession(sessionID: UUID) async { await coordinator.discardSession(sessionID: sessionID) }
    public nonisolated func endAudio() async { await coordinator.finishCapture() }
}

/// The buffer is copied in the tap and then has a single reader on the control queue.
private struct NativeSpeechAudio: @unchecked Sendable { let buffer: AVAudioPCMBuffer }

private final class NativeSpeechSessionDriver: SpeechSessionDriver, @unchecked Sendable {
    private let request: TranscriptionRequest
    private let queue: DispatchQueue
    private var recognizer: SFSpeechRecognizer?
    private var audio: AVAudioEngine?
    private var tapInstalled = false
    /// 采集前的会话状态快照：非 nil 即「类别已改、拆除时必还原」——
    /// 判定挂快照而非「激活成功」（setActive 抛错时类别已改也必须还原）。
    /// iOS-only：AVAudioSession 在 macOS 不可用（CI 34018308312 同族），
    /// macOS 测试宿主走无会话路径（AVAudioEngine 直连，无路由概念）。
    #if os(iOS)
    private var sessionState: AudioSessionCapture.State?
    #endif
    private var observers: [NSObjectProtocol] = []
    private var requests: [UUID: SFSpeechAudioBufferRecognitionRequest] = [:]
    private var tasks: [UUID: SFSpeechRecognitionTask] = [:]
    private var ended: Set<UUID> = []
    private(set) var resolvedLocale = ""

    init(request: TranscriptionRequest, queue: DispatchQueue) {
        self.request = request
        self.queue = queue
    }

    func authorize(_ completion: @escaping @Sendable (Bool) -> Void,
                   isStopped: @escaping @Sendable () -> Bool) {
        guard !isStopped() else { completion(false); return }
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized, !isStopped() else { completion(false); return }
            AVAudioApplication.requestRecordPermission { granted in completion(granted && !isStopped()) }
        }
    }

    func startRecognition(id: UUID, onEvent: @escaping @Sendable (SpeechRecognitionEvent) -> Void) throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw TranscriptionError.unauthorized
        }
        if recognizer == nil {
            let capability = SFSpeechTranscriber.probeCapability()
            guard let locale = capability.resolvedLocale(for: request.localeIdentifier),
                  let candidate = SFSpeechRecognizer(locale: Locale(identifier: locale)),
                  TranscriptionLocale.normalizedIdentifier(candidate.locale.identifier)
                    == TranscriptionLocale.normalizedIdentifier(locale) else {
                throw TranscriptionError.engineUnavailable
            }
            let callbacks = OperationQueue()
            callbacks.maxConcurrentOperationCount = 1
            callbacks.underlyingQueue = queue
            candidate.queue = callbacks
            resolvedLocale = candidate.locale.identifier
            recognizer = candidate
        }
        guard let recognizer, recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            throw TranscriptionError.engineUnavailable
        }
        let native = SFSpeechAudioBufferRecognitionRequest()
        native.requiresOnDeviceRecognition = true
        native.shouldReportPartialResults = true
        native.taskHint = .dictation
        native.contextualStrings = Array(request.contextualStrings.prefix(MixedSpeechVocabulary.limit))
        requests[id] = native
        let started = recognizer.recognitionTask(with: native) { result, error in
            let segments = result?.bestTranscription.segments ?? []
            let confidence = segments.isEmpty ? 0 : Double(segments.map(\.confidence).reduce(0, +) / Float(segments.count))
            let failure: SpeechRecognitionFailure?
            if let error {
                let nativeError = error as NSError
                // Only the no-speech endpoint is recoverable. Do not retry arbitrary assistant errors (e.g. 1101).
                failure = nativeError.domain == "kAFAssistantErrorDomain" && nativeError.code == 1110
                    ? .noSpeech : .unavailable
            } else {
                failure = nil
            }
            onEvent(SpeechRecognitionEvent(text: result?.bestTranscription.formattedString,
                                           isFinal: result?.isFinal ?? false,
                                           confidence: confidence, failure: failure))
        }
        if requests[id] != nil { tasks[id] = started } else { started.cancel() }
    }

    func startCapture(onAudio: @escaping @Sendable (SpeechAudioChunk<NativeSpeechAudio>) -> Void,
                      onFailure: @escaping @Sendable () -> Void,
                      isStopped: @escaping @Sendable () -> Bool) throws {
        guard !isStopped() else { throw CancellationError() }
        #if os(iOS)
        // 采集激活单一出口 + 先记状态后激活：setActive 失败时类别已被修改，
        // 快照在场即保证拆除路径必还原（共享会话不再有停留在 .record 的窗口）
        let prior = AudioSessionCapture.remember()
        do { try AudioSessionCapture.activateRecordSession() }
        catch {
            AudioSessionCapture.restore(prior)
            throw error
        }
        sessionState = prior
        #endif
        let engine = AVAudioEngine()
        audio = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TranscriptionError.engineUnavailable
        }
        guard !isStopped() else { throw CancellationError() }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard buffer.frameLength > 0 else { return }
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let byteCount = source.reduce(0) { $0 + Int($1.mDataByteSize) }
            guard byteCount <= SpeechSessionLimits().maximumBufferedBytes,
                  let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                onFailure()
                return
            }
            copy.frameLength = buffer.frameLength
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            var bytes = 0
            for index in source.indices {
                guard destination.indices.contains(index),
                      source[index].mDataByteSize == destination[index].mDataByteSize,
                      let from = source[index].mData, let to = destination[index].mData else { onFailure(); return }
                let count = Int(source[index].mDataByteSize)
                memcpy(to, from, count)
                bytes += count
            }
            onAudio(SpeechAudioChunk(buffer: NativeSpeechAudio(buffer: copy),
                                    duration: Double(copy.frameLength) / copy.format.sampleRate, byteCount: bytes))
        }
        tapInstalled = true
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                 object: engine, queue: nil) { _ in onFailure() })
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                 object: nil, queue: nil) { _ in onFailure() })
        #endif
        guard !isStopped() else { throw CancellationError() }
        engine.prepare()
        try engine.start()
        if isStopped() { throw CancellationError() }
    }

    func stopCapture() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let audio {
            audio.stop()
            if tapInstalled { audio.inputNode.removeTap(onBus: 0) }
        }
        tapInstalled = false
        audio = nil
        #if os(iOS)
        if let prior = sessionState {
            // 采集拆除单一出口（对称还原采集前状态）：只停用不还原类别会让
            // 共享会话停留在 .record——其后的 FR17.13 回读 / FR17.11 提问朗读 /
            // FR19.3 播报全部路由到听筒（Sherpa 主轨同款缺陷的降级轨复现，
            // 主轨已修、降级轨漏修）。快照还原，不再硬编码 .playback。
            AudioSessionCapture.restore(prior)
            sessionState = nil
        }
        #endif
    }

    func append(_ audio: NativeSpeechAudio, to id: UUID) {
        guard !ended.contains(id) else { return }
        requests[id]?.append(audio.buffer)
    }

    func endAudio(id: UUID) {
        guard ended.insert(id).inserted else { return }
        requests[id]?.endAudio()
    }

    func cancelRecognition(id: UUID) {
        let task = tasks.removeValue(forKey: id)
        requests[id] = nil
        ended.remove(id)
        task?.cancel()
    }
}
#endif
