import Foundation
import Testing
import Domain
@testable import Infrastructure

// binds: SU-M15-VOICE (FR17.1, FR17.7, FR17.15)
@Suite("Speech lifecycle and audio handoff", .timeLimit(.minutes(1)))
struct SpeechLifecycleTests {
    @Test func abandonedUnregisteredRequestCannotStartLater() async throws {
        let driver = ManualSpeechDriver()
        let engine = SpeechSessionCoordinator { _ in driver }
        let request = TranscriptionRequest(localeIdentifier: "en-US")
        await engine.cancel(sessionID: request.sessionID)
        await engine.discardSession(sessionID: request.sessionID)
        do {
            _ = try await engine.transcribe(request, onPartial: nil)
            Issue.record("An abandoned press must not restart capture")
        } catch {
            #expect(driver.snapshot().events.isEmpty)
        }
    }

    @Test func cancelBeforeRegistrationCannotStartAuthorizationOrCapture() async throws {
        let driver = ManualSpeechDriver()
        let engine = SpeechSessionCoordinator { _ in driver }
        let request = TranscriptionRequest(localeIdentifier: "en-US")
        await engine.cancel(sessionID: request.sessionID)
        do {
            _ = try await engine.transcribe(request, onPartial: nil)
            Issue.record("Cancelled request unexpectedly completed")
        } catch is CancellationError {
            #expect(driver.snapshot().events.isEmpty)
        }
    }

    @Test func finishDuringAuthorizationSettlesAndIgnoresLateApproval() async throws {
        let driver = ManualSpeechDriver()
        let engine = SpeechSessionCoordinator { _ in driver }
        let request = TranscriptionRequest(localeIdentifier: "en-US")
        let work = Task { try await engine.transcribe(request, onPartial: nil) }
        await driver.waitFor("authorize")
        await engine.finish(sessionID: request.sessionID)
        let result = try await work.value
        #expect(result.text.isEmpty)
        driver.approve()
        await engine.finish(sessionID: request.sessionID)
        #expect(!driver.snapshot().events.contains("capture"))
    }

    @Test func releaseStopsCaptureBeforeFinalAndTimeoutPreservesPartial() async throws {
        let driver = ManualSpeechDriver()
        var limits = SpeechSessionLimits()
        limits.finalizationTimeout = 0.02
        let engine = SpeechSessionCoordinator(limits: limits) { _ in driver }
        let request = TranscriptionRequest(localeIdentifier: "en-US")
        let work = Task { try await engine.transcribe(request, onPartial: nil) }
        await driver.waitFor("authorize")
        driver.approve()
        await driver.waitFor("capture")
        driver.emit(segment: 0, text: "retained partial")
        await engine.finish(sessionID: request.sessionID)
        #expect(!driver.snapshot().capturing)
        let result = try await work.value
        #expect(result.text == "retained partial")
        #expect(result.completion == .timedOut)
        #expect(result.confidence == 0)
        #expect(driver.snapshot().cancelledSegments == [0])
    }

    @Test func stopWhileNativeSetupIsBusyPreventsHardwareStart() async throws {
        let driver = ManualSpeechDriver(pauseBeforeCapture: true)
        let engine = SpeechSessionCoordinator { _ in driver }
        let request = TranscriptionRequest(localeIdentifier: "en-US")
        let work = Task { try await engine.transcribe(request, onPartial: nil) }
        await driver.waitFor("authorize")
        driver.approve()
        await driver.waitFor("setup")
        await engine.finish(sessionID: request.sessionID)
        #expect(!driver.snapshot().events.contains("capture"))
        driver.emit(segment: 0, text: "", isFinal: true)
        let result = try await work.value
        #expect(result.text.isEmpty)
    }

    @Test func cancellationSettlesWithoutAnyRecognitionCallback() async throws {
        let driver = ManualSpeechDriver()
        let engine = SpeechSessionCoordinator { _ in driver }
        let request = TranscriptionRequest(localeIdentifier: "en-US")
        let work = Task { try await engine.transcribe(request, onPartial: nil) }
        await driver.waitFor("authorize")
        driver.approve()
        await driver.waitFor("capture")
        work.cancel()
        do {
            _ = try await work.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(!driver.snapshot().capturing)
            #expect(driver.snapshot().cancelledSegments == [0])
        }
        driver.emit(segment: 0, text: "late", isFinal: true)
        await engine.cancel(sessionID: request.sessionID)
        #expect(driver.snapshot().events.filter { $0 == "stop" }.count == 1)
    }

    @Test func latchedCancellationDoesNotFeedTheRestOfAQueuedAudioBatch() async throws {
        let driver = ManualSpeechDriver(pauseDuringAppend: true)
        let engine = SpeechSessionCoordinator { _ in driver }
        let request = TranscriptionRequest(localeIdentifier: "en-US")
        let work = Task { try await engine.transcribe(request, onPartial: nil) }
        await driver.waitFor("authorize")
        driver.approve()
        await driver.waitFor("capture")
        driver.audio(1)
        driver.audio(2)
        await driver.waitFor("append")
        await engine.cancel(sessionID: request.sessionID)
        do {
            _ = try await work.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(driver.snapshot().appended[0] == [1])
            #expect(!driver.snapshot().capturing)
        }
    }

    @Test func nextCaptureStartsOnlyAfterPredecessorStopsButDoesNotWaitForItsFinal() async throws {
        let first = ManualSpeechDriver()
        let second = ManualSpeechDriver()
        let a = TranscriptionRequest(localeIdentifier: "en-US")
        let b = TranscriptionRequest(localeIdentifier: "en-US")
        let engine = SpeechSessionCoordinator { request in request.sessionID == a.sessionID ? first : second }
        let firstWork = Task { try await engine.transcribe(a, onPartial: nil) }
        await first.waitFor("authorize")
        first.approve()
        await first.waitFor("capture")
        first.emit(segment: 0, text: "first")
        let secondWork = Task { try await engine.transcribe(b, onPartial: nil) }
        await second.waitFor("authorize")
        #expect(!first.snapshot().capturing)
        second.approve()
        await second.waitFor("capture")
        #expect(second.snapshot().capturing)
        #expect(first.snapshot().endedSegments == [0])
        await engine.finish(sessionID: b.sessionID)
        second.emit(segment: 0, text: "second", isFinal: true)
        first.emit(segment: 0, text: "first", isFinal: true)
        let firstResult = try await firstWork.value
        let secondResult = try await secondWork.value
        #expect(firstResult.text == "first")
        #expect(secondResult.text == "second")
    }

    @Test func rolloverBuffersAudioUntilFinalAndRejectsStaleSegmentCallbacks() async throws {
        let driver = ManualSpeechDriver()
        let updates = SpeechTextLog()
        var limits = SpeechSessionLimits()
        limits.rotationInterval = 0.03
        let engine = SpeechSessionCoordinator(limits: limits) { _ in driver }
        let request = TranscriptionRequest(localeIdentifier: "en-US")
        let work = Task { try await engine.transcribe(request, onPartial: { updates.append($0) }) }
        await driver.waitFor("authorize")
        driver.approve()
        await driver.waitFor("capture")
        driver.emit(segment: 0, text: "first")
        await driver.waitFor("end.0")
        driver.audio(11)
        driver.audio(12)
        driver.emit(segment: 0, text: "first", isFinal: true)
        await driver.waitFor("segment.1")
        driver.emit(segment: 0, text: "stale old callback")
        driver.emit(segment: 1, text: "second")
        await engine.finish(sessionID: request.sessionID)
        driver.emit(segment: 1, text: "second", isFinal: true)
        let result = try await work.value
        #expect(result.segments == ["first", "second"])
        #expect(driver.snapshot().appended[1] == [11, 12])
        #expect(driver.snapshot().appendsAfterEnd == 0)
        #expect(!updates.values.contains(where: { $0.contains("stale") }))
        #expect(updates.values.last == "first second")
    }

    @Test func initialNoSpeechDoesNotEndHeldCaptureAndRecoveryKeepsPartial() async throws {
        let driver = ManualSpeechDriver()
        var limits = SpeechSessionLimits()
        limits.restartDelay = 0.001
        let engine = SpeechSessionCoordinator(limits: limits) { _ in driver }
        let request = TranscriptionRequest(localeIdentifier: "en-US")
        let work = Task { try await engine.transcribe(request, onPartial: nil) }
        await driver.waitFor("authorize")
        driver.approve()
        await driver.waitFor("capture")
        driver.emit(segment: 0, failure: .noSpeech)
        await driver.waitFor("segment.1")
        #expect(driver.snapshot().capturing)
        driver.emit(segment: 1, text: "before error")
        driver.emit(segment: 1, failure: .noSpeech)
        await driver.waitFor("segment.2")
        driver.emit(segment: 2, text: "after error")
        await engine.finish(sessionID: request.sessionID)
        driver.emit(segment: 2, text: "", isFinal: true)
        let result = try await work.value
        #expect(result.segments == ["before error", "after error"])
        #expect(result.completion == .partial)
        #expect(result.confidence == 0)
    }

    @Test func fatalErrorAfterTextStopsRatherThanRestarting() async throws {
        let driver = ManualSpeechDriver()
        let engine = SpeechSessionCoordinator { _ in driver }
        let request = TranscriptionRequest(localeIdentifier: "en-US")
        let work = Task { try await engine.transcribe(request, onPartial: nil) }
        await driver.waitFor("authorize")
        driver.approve()
        await driver.waitFor("capture")
        driver.emit(segment: 0, text: "preserve this")
        driver.emit(segment: 0, failure: .unavailable)
        let result = try await work.value
        #expect(result.text == "preserve this")
        #expect(result.completion == .interrupted)
        #expect(!driver.snapshot().capturing)
        #expect(driver.snapshot().segmentCount == 1)
    }

    @Test func handoffOverflowStopsWithExplicitIncompleteResult() async throws {
        let driver = ManualSpeechDriver()
        var limits = SpeechSessionLimits()
        limits.rotationInterval = 0.02
        limits.maximumBufferedSeconds = 0.15
        let engine = SpeechSessionCoordinator(limits: limits) { _ in driver }
        let request = TranscriptionRequest(localeIdentifier: "en-US")
        let work = Task { try await engine.transcribe(request, onPartial: nil) }
        await driver.waitFor("authorize")
        driver.approve()
        await driver.waitFor("capture")
        driver.emit(segment: 0, text: "preserved")
        await driver.waitFor("end.0")
        driver.audio(1, duration: 0.1)
        driver.audio(2, duration: 0.1)
        let result = try await work.value
        #expect(result.text == "preserved")
        #expect(result.completion == .bufferOverflow)
        #expect(!driver.snapshot().capturing)
        #expect(driver.snapshot().appendsAfterEnd == 0)
    }

    @Test func repeatedMissingFinalsExhaustRecoveryBudgetAndStopCapture() async throws {
        let driver = ManualSpeechDriver()
        var limits = SpeechSessionLimits()
        limits.rotationInterval = 0.01
        limits.finalizationTimeout = 0.01
        limits.restartDelay = 0.001
        let engine = SpeechSessionCoordinator(limits: limits) { _ in driver }
        let request = TranscriptionRequest(localeIdentifier: "en-US")
        let work = Task { try await engine.transcribe(request, onPartial: nil) }
        await driver.waitFor("authorize")
        driver.approve()
        await driver.waitFor("capture")
        driver.emit(segment: 0, text: "retained")
        let result = try await work.value
        #expect(result.text == "retained")
        #expect(result.completion == .timedOut)
        #expect(driver.snapshot().segmentCount == 3)
        #expect(!driver.snapshot().capturing)
    }
}

private final class SpeechTextLog: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    func append(_ text: String) { lock.lock(); texts.append(text); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return texts }
}

/// Only the native boundaries are replaced; coordinator state, timers, buffering and cancellation are real.
private final class ManualSpeechDriver: SpeechSessionDriver, @unchecked Sendable {
    typealias Audio = Int
    let resolvedLocale = "en-US"
    private let pauseBeforeCapture: Bool
    private let pauseDuringAppend: Bool
    private let lock = NSLock()
    private var authorization: (@Sendable (Bool) -> Void)?
    private var audioHandler: (@Sendable (SpeechAudioChunk<Int>) -> Void)?
    private var isStopped: (@Sendable () -> Bool)?
    private var handlers: [UUID: @Sendable (SpeechRecognitionEvent) -> Void] = [:]
    private var segments: [UUID] = []
    private var ended: Set<UUID> = []
    private var cancelled: Set<UUID> = []
    private var frames: [UUID: [Int]] = [:]
    private var capturing = false
    private var appendsAfterEnd = 0
    private var events: [String] = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(pauseBeforeCapture: Bool = false, pauseDuringAppend: Bool = false) {
        self.pauseBeforeCapture = pauseBeforeCapture
        self.pauseDuringAppend = pauseDuringAppend
    }

    private func waitForStop(_ isStopped: @Sendable () -> Bool) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !isStopped(), clock.now < deadline { Thread.sleep(forTimeInterval: 0.001) }
    }

    struct Snapshot: Sendable {
        var capturing: Bool
        var events: [String]
        var segmentCount: Int
        var endedSegments: Set<Int>
        var cancelledSegments: Set<Int>
        var appended: [Int: [Int]]
        var appendsAfterEnd: Int
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(capturing: capturing, events: events, segmentCount: segments.count,
                        endedSegments: Set(segments.indices.filter { ended.contains(segments[$0]) }),
                        cancelledSegments: Set(segments.indices.filter { cancelled.contains(segments[$0]) }),
                        appended: Dictionary(uniqueKeysWithValues: segments.indices.map { ($0, frames[segments[$0]] ?? []) }),
                        appendsAfterEnd: appendsAfterEnd)
    }

    private func record(_ event: String) {
        lock.lock()
        events.append(event)
        let ready = waiters.removeValue(forKey: event) ?? []
        lock.unlock()
        ready.forEach { $0.resume() }
    }

    func waitFor(_ event: String) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let ready = events.contains(event)
            if !ready { waiters[event, default: []].append(continuation) }
            lock.unlock()
            if ready { continuation.resume() }
        }
    }

    func authorize(_ completion: @escaping @Sendable (Bool) -> Void,
                   isStopped: @escaping @Sendable () -> Bool) {
        lock.lock(); authorization = completion; lock.unlock()
        record("authorize")
    }

    func approve() {
        lock.lock(); let callback = authorization; lock.unlock()
        callback?(true)
    }

    func startCapture(onAudio: @escaping @Sendable (SpeechAudioChunk<Int>) -> Void,
                      onFailure: @escaping @Sendable () -> Void,
                      isStopped: @escaping @Sendable () -> Bool) throws {
        if pauseBeforeCapture {
            record("setup")
            waitForStop(isStopped)
            if isStopped() { throw CancellationError() }
        }
        lock.lock(); capturing = true; audioHandler = onAudio; self.isStopped = isStopped; lock.unlock()
        record("capture")
    }

    func stopCapture() {
        lock.lock(); let wasCapturing = capturing; capturing = false; lock.unlock()
        if wasCapturing { record("stop") }
    }

    func startRecognition(id: UUID, onEvent: @escaping @Sendable (SpeechRecognitionEvent) -> Void) throws {
        lock.lock()
        let index = segments.count
        segments.append(id)
        handlers[id] = onEvent
        lock.unlock()
        record("segment.\(index)")
    }

    func append(_ audio: Int, to id: UUID) {
        if pauseDuringAppend {
            record("append")
            lock.lock(); let check = isStopped; lock.unlock()
            if let check { waitForStop(check) }
        }
        lock.lock()
        if ended.contains(id) { appendsAfterEnd += 1 }
        frames[id, default: []].append(audio)
        lock.unlock()
    }

    func endAudio(id: UUID) {
        lock.lock()
        ended.insert(id)
        let index = segments.firstIndex(of: id)!
        lock.unlock()
        record("end.\(index)")
    }

    func cancelRecognition(id: UUID) {
        lock.lock(); cancelled.insert(id); lock.unlock()
    }

    func audio(_ sequence: Int, duration: TimeInterval = 0.02) {
        lock.lock(); let callback = audioHandler; lock.unlock()
        callback?(SpeechAudioChunk(buffer: sequence, duration: duration, byteCount: 32))
    }

    func emit(segment index: Int, text: String? = nil, isFinal: Bool = false,
              failure: SpeechRecognitionFailure? = nil) {
        lock.lock(); let callback = handlers[segments[index]]; lock.unlock()
        callback?(SpeechRecognitionEvent(text: text, isFinal: isFinal, confidence: 0.9, failure: failure))
    }
}
