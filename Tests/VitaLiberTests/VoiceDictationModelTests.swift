import XCTest
import Foundation
import Domain
import Protocols
@testable import VitaLiber

// binds: SU-M15-VOICE (FR17.1, FR17.15, BR-012)
@MainActor
final class VoiceDictationModelTests: XCTestCase {
    /// Deliberately ignores cancellation so late native callbacks remain testable.
    private actor ControlledEngine: TranscriptionEngine {
        nonisolated let capability = TranscriptionCapability.baseline(locales: ["zh-Hans-CN", "en-US"])
        private var requests: [TranscriptionRequest] = []
        private var waitingRequests: [Int: CheckedContinuation<TranscriptionRequest, Never>] = [:]
        private var continuations: [UUID: CheckedContinuation<TranscriptionResult, Error>] = [:]
        private var partials: [UUID: @Sendable (String) -> Void] = [:]
        private var finishWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        private(set) var finished: Set<UUID> = []
        private(set) var cancelled: Set<UUID> = []

        func transcribe(_ request: TranscriptionRequest,
                        onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
            try await withCheckedThrowingContinuation { continuation in
                continuations[request.sessionID] = continuation
                partials[request.sessionID] = onPartial
                let index = requests.count
                requests.append(request)
                waitingRequests.removeValue(forKey: index)?.resume(returning: request)
            }
        }

        func request(at index: Int) async -> TranscriptionRequest {
            if requests.indices.contains(index) { return requests[index] }
            return await withCheckedContinuation { waitingRequests[index] = $0 }
        }

        func finish(sessionID: UUID) async {
            finished.insert(sessionID)
            finishWaiters.removeValue(forKey: sessionID)?.resume()
        }
        func cancel(sessionID: UUID) async { cancelled.insert(sessionID) }

        func waitForFinish(sessionID: UUID) async {
            if finished.contains(sessionID) { return }
            await withCheckedContinuation { finishWaiters[sessionID] = $0 }
        }

        func emit(_ text: String, for request: TranscriptionRequest) {
            partials[request.sessionID]?(text)
        }

        func complete(_ request: TranscriptionRequest, text: String,
                      locale: String? = nil, completion: TranscriptionCompletion = .final,
                      hypotheses: [TranscriptionHypothesis] = []) {
            continuations.removeValue(forKey: request.sessionID)?.resume(returning:
                TranscriptionResult(text: text, confidence: 0.9,
                                    resolvedLocale: locale ?? request.localeIdentifier,
                                    segmented: false, segments: [text], completion: completion,
                                    hypotheses: hypotheses))
        }

        func fail(_ request: TranscriptionRequest) {
            continuations.removeValue(forKey: request.sessionID)?.resume(throwing: TranscriptionError.noSpeechDetected)
        }
    }

    private func eventually(_ condition: @MainActor () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let clock = ContinuousClock()
        // 审查修复：轮询窗口由 2s 提到 10s——引擎回调需经 actor → MainActor
        // 跳转投递，并发 shard 争抢下墙钟 2s 可能不足（sleep-then-assert
        // 模式的时间敏感假失败；10s 远大于任何调度抖动，仍为有界等待）。
        let deadline = clock.now.advanced(by: .seconds(10))
        while !condition(), clock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func test_reverseFinalsAreDeliveredInPressOrderWithoutStaleLocale() async {
        let engine = ControlledEngine()
        let model = VoiceDictationModel(engine: engine, preferredLocale: "zh-Hans-CN")
        var delivered: [String] = []
        model.onTranscript = { text, _ in delivered.append(text) }
        model.start()
        let first = await engine.request(at: 0)
        model.stop()
        model.preferredLocale = "en-US"
        model.start()
        let second = await engine.request(at: 1)
        await engine.complete(second, text: "second", locale: "en-US")
        await eventually { model.phase == .idle }
        XCTAssertTrue(delivered.isEmpty, "A faster second final must wait for the first press")
        await engine.complete(first, text: "first", locale: "zh-Hans-CN")
        await eventually { delivered.count == 2 }
        XCTAssertEqual(delivered, ["first", "second"])
        XCTAssertEqual(model.resolvedLocale, "en-US")
        XCTAssertFalse(model.isBestEffortFallback)
    }

    func test_hardStopInvalidatesEveryOldSessionAcrossRestart() async {
        let engine = ControlledEngine()
        let model = VoiceDictationModel(engine: engine, preferredLocale: "zh-Hans-CN")
        var delivered: [String] = []
        model.onTranscript = { text, _ in delivered.append(text) }
        model.start()
        let first = await engine.request(at: 0)
        model.stop()
        model.start()
        let second = await engine.request(at: 1)
        model.stopForDisappear()
        model.start()
        let third = await engine.request(at: 2)
        await engine.complete(second, text: "discard second")
        await engine.complete(first, text: "discard first")
        await engine.complete(third, text: "keep third")
        await eventually { delivered == ["keep third"] && !model.hasPendingTranscriptions }
        let cancelled = await engine.cancelled
        XCTAssertEqual(cancelled, [first.sessionID, second.sessionID])
    }

    func test_stopBeforeScheduledStartUsesTheSameRequestID() async {
        let engine = ControlledEngine()
        let model = VoiceDictationModel(engine: engine, preferredLocale: "zh-Hans-CN")
        model.start()
        model.stop()
        let request = await engine.request(at: 0)
        await engine.waitForFinish(sessionID: request.sessionID)
        await engine.complete(request, text: "")
        await eventually { !model.hasPendingTranscriptions }
        let finished = await engine.finished
        XCTAssertEqual(finished, [request.sessionID])
    }

    func test_sessionContextSnapshotsLanguageVocabularyAndCallback() async {
        let engine = ControlledEngine()
        let model = VoiceDictationModel(engine: engine)
        model.applyLanguageSettings(storedLocales: "en-US,zh-Hans-CN", mixedInput: true,
                                    recentDrugNames: ["ibuprofen"])
        var original: [String] = []
        var replacement: [String] = []
        model.onTranscript = { text, _ in original.append(text) }
        model.start()
        model.applyLanguageSettings(storedLocales: "zh-Hans-CN", mixedInput: false, recentDrugNames: [])
        model.onTranscript = { text, _ in replacement.append(text) }
        let request = await engine.request(at: 0)
        XCTAssertEqual(request.localeIdentifier, "en-US")
        XCTAssertEqual(request.contextualStrings.first, "ibuprofen")
        XCTAssertTrue(request.contextualStrings.contains("mmHg"))
        await engine.complete(request, text: "original callback")
        await eventually { original == ["original callback"] }
        XCTAssertTrue(replacement.isEmpty)
        XCTAssertFalse(model.isBestEffortFallback, "Compare with this press's language, not changed settings")
    }

    func test_oldPartialCannotSuppressIdenticalCurrentPartial() async {
        let engine = ControlledEngine()
        let model = VoiceDictationModel(engine: engine, preferredLocale: "zh-Hans-CN")
        model.start()
        let first = await engine.request(at: 0)
        model.stop()
        model.start()
        let second = await engine.request(at: 1)
        await engine.emit("same words", for: first)
        await engine.emit("same words", for: second)
        await eventually { model.partial == "same words" }
        await engine.complete(first, text: "first")
        await engine.complete(second, text: "second")
        await eventually { !model.hasPendingTranscriptions }
    }

    func test_failedEarlierSessionDoesNotBlockLaterFinal() async {
        let engine = ControlledEngine()
        let model = VoiceDictationModel(engine: engine, preferredLocale: "zh-Hans-CN")
        var delivered: [String] = []
        model.onTranscript = { text, _ in delivered.append(text) }
        model.start()
        let first = await engine.request(at: 0)
        model.stop()
        model.start()
        let second = await engine.request(at: 1)
        await engine.complete(second, text: "survivor")
        await engine.fail(first)
        await eventually { delivered == ["survivor"] && !model.hasPendingTranscriptions }
    }

    func test_authorizationWithdrawalRejectsLateTextAndNewStarts() async {
        let engine = ControlledEngine()
        let model = VoiceDictationModel(engine: engine, preferredLocale: "zh-Hans-CN")
        var delivered: [String] = []
        model.onTranscript = { text, _ in delivered.append(text) }
        model.start()
        let request = await engine.request(at: 0)
        model.setAuthorization(false)
        model.start()
        await engine.complete(request, text: "revoked")
        await eventually { !model.hasPendingTranscriptions }
        XCTAssertNotEqual(model.phase, .recording)
        XCTAssertTrue(delivered.isEmpty)
        model.setAuthorization(true)
        model.start()
        let resumed = await engine.request(at: 1)
        await engine.complete(resumed, text: "authorized again")
        await eventually { delivered == ["authorized again"] }
    }

    func test_incompleteFinalKeepsTextButNeverKeepsHighConfidence() async {
        let engine = ControlledEngine()
        let model = VoiceDictationModel(engine: engine, preferredLocale: "zh-Hans-CN")
        var delivered: [(String, Double)] = []
        model.onTranscript = { delivered.append(($0, $1)) }
        model.start()
        let request = await engine.request(at: 0)
        await engine.complete(request, text: "retained partial", completion: .timedOut)
        await eventually { delivered.count == 1 }
        XCTAssertEqual(delivered.first?.0, "retained partial")
        XCTAssertEqual(delivered.first?.1, 0)
        XCTAssertTrue(model.hasIncompleteTranscript)
    }

    func test_activityRemainsBusyWhileDrainingAndClearsSynchronouslyOnRevoke() async {
        let engine = ControlledEngine()
        let model = VoiceDictationModel(engine: engine, preferredLocale: "en-US")
        var activity: [Bool] = []
        model.onActivityChange = { activity.append($0) }
        model.start()
        XCTAssertEqual(activity, [true])
        let request = await engine.request(at: 0)
        model.stop()
        XCTAssertEqual(activity, [true], "Release must not enable advancing a guided field before its final")
        model.setAuthorization(false)
        XCTAssertEqual(activity, [true, false], "Revocation must not leave the manual-input path disabled")
        await engine.complete(request, text: "late")
    }

    /// round3 P0-B · BR-012: a raw engine 1-best hit routes to emergency even when the delivered text missed it.
    func test_rawHypothesisEmergencyRoutesInsteadOfDraft() async {
        let engine = ControlledEngine()
        let model = VoiceDictationModel(engine: engine, preferredLocale: "zh-Hans-CN")
        var delivered: [String] = []
        var emergencies: [String] = []
        model.onTranscript = { text, _ in delivered.append(text) }
        model.onEmergency = { text in emergencies.append(text) }
        model.start()
        let request = await engine.request(at: 0)
        await engine.complete(request, text: "我兄通得厉害", hypotheses: [
            TranscriptionHypothesis(engineID: "qwen3", text: "我兄通得厉害"),
            TranscriptionHypothesis(engineID: "classic", text: "我胸痛得厉害"),
        ])
        await eventually { emergencies == ["我胸痛得厉害"] && !model.hasPendingTranscriptions }
        XCTAssertTrue(delivered.isEmpty, "An emergency hit must not also become a draft")
    }

    /// round3 P0-B · BR-012: an empty primary with an emergency hypothesis is an emergency, not "no speech".
    func test_emptyDeliveredTextWithEmergencyHypothesisIsNotNoSpeech() async {
        let engine = ControlledEngine()
        let model = VoiceDictationModel(engine: engine, preferredLocale: "zh-Hans-CN")
        var emergencies: [String] = []
        var failures = 0
        model.onEmergency = { text in emergencies.append(text) }
        model.onFailure = { _, _ in failures += 1 }
        model.start()
        let request = await engine.request(at: 0)
        await engine.complete(request, text: "", hypotheses: [
            TranscriptionHypothesis(engineID: "sensevoice", text: "救命"),
        ])
        await eventually { emergencies == ["救命"] && !model.hasPendingTranscriptions }
        XCTAssertEqual(failures, 0)
        XCTAssertNotEqual(model.phase, .failed)
        XCTAssertNil(model.failureReason)
    }

    /// round3 P0-B · BR-012: lower-ranked n-best of the same engine never triggers emergency.
    func test_nBestOnlyEmergencyStillDeliversDraft() async {
        let engine = ControlledEngine()
        let model = VoiceDictationModel(engine: engine, preferredLocale: "zh-Hans-CN")
        var delivered: [String] = []
        var emergencies: [String] = []
        model.onTranscript = { text, _ in delivered.append(text) }
        model.onEmergency = { text in emergencies.append(text) }
        model.start()
        let request = await engine.request(at: 0)
        await engine.complete(request, text: "我兄通得厉害", hypotheses: [
            TranscriptionHypothesis(engineID: "classic", text: "我兄通得厉害", alternativeTexts: ["我胸痛得厉害"]),
        ])
        await eventually { delivered == ["我兄通得厉害"] && !model.hasPendingTranscriptions }
        XCTAssertTrue(emergencies.isEmpty)
    }

    /// round3 P0-B · FR17.15: mixed input off still injects confirmed drug names (only), single-language decode.
    func test_singleLanguageModeStillInjectsConfirmedDrugNamesOnly() async {
        let engine = ControlledEngine()
        let model = VoiceDictationModel(engine: engine)
        model.applyLanguageSettings(storedLocales: "zh-Hans-CN,en-US", mixedInput: false,
                                    recentDrugNames: ["阿莫西林胶囊", "阿莫西林胶囊", "Metformin"])
        model.start()
        let request = await engine.request(at: 0)
        XCTAssertEqual(request.languageMode, .single)
        XCTAssertEqual(request.contextualStrings, ["阿莫西林胶囊", "Metformin"])
        await engine.complete(request, text: "done")
        await eventually { !model.hasPendingTranscriptions }
    }
}
