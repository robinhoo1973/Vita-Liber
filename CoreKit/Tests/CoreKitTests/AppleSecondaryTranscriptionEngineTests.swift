import Foundation
import Testing
@testable import Domain
@testable import Protocols
@testable import Infrastructure

// binds: SU-M15-ASRAPPLE — 主轨先完成采集；Apple zh-CN/en-US 仅作采集后第二/第三文本假设；交付文本不改写
/// 业主 2026-11-05 修正：没有三源实时并行。主轨先完成采集，Apple zh-CN/en-US
/// 仅作为采集后的第二/第三文本假设；交付文本不改写。
@Suite("SU-M15-ASRAPPLE · Apple 采集后副源")
struct AppleSecondaryTranscriptionEngineTests {
    private static let request = TranscriptionRequest(localeIdentifier: "zh-Hans-CN",
                                                      contextualStrings: ["阿莫西林"])

    @Test func appleSourcesRunOnlyAfterPrimaryAndDoNotRewriteDeliveredText() async throws {
        let primary = FakePrimary(result: Self.primaryResult(engineID: "qwen3"), waitForRelease: true)
        let apples = FakeApple()
        let engine = AppleSecondaryTranscriptionEngine(primary: primary, apples: apples)

        let task = Task { try await engine.transcribe(Self.request, onPartial: nil) }
        let started = primary.started
        await started.wait()
        let callsBeforePrimary = await apples.calls()
        #expect(callsBeforePrimary.isEmpty)

        let release = primary.release
        await release.set()
        let result = try await task.value

        let callsAfterPrimary = await apples.calls()
        #expect(result.text == "primary")
        #expect(result.confidence == 0.9)
        #expect(result.hypotheses.map(\.engineID).sorted() == ["apple-en-US", "apple-zh-CN", "qwen3"])
        // 采集后两个 Apple 文件识别可并行，完成顺序不承诺；只断言两源都跑到。
        #expect(Set(callsAfterPrimary.map(\.role)) == Set([.secondAppleChinese, .thirdAppleEnglish]))
    }

    @Test func classicChinesePrimarySkipsDuplicateAppleChineseSource() async throws {
        let primary = FakePrimary(result: Self.primaryResult(engineID: "classic",
                                                             locale: "zh-CN"))
        let apples = FakeApple()
        let engine = AppleSecondaryTranscriptionEngine(primary: primary, apples: apples)

        let result = try await engine.transcribe(Self.request, onPartial: nil)

        let calls = await apples.calls()
        #expect(result.text == "primary")
        #expect(calls.map(\.role) == [.thirdAppleEnglish])
        #expect(result.hypotheses.contains { $0.engineID == "apple-en-US" })
        #expect(!result.hypotheses.contains { $0.engineID == "apple-zh-CN" })
    }

    @Test func callerRecordingURLIsNotDeleted() async throws {
        let callerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caller-\(UUID().uuidString).caf")
        try Data("audio".utf8).write(to: callerURL)
        defer { try? FileManager.default.removeItem(at: callerURL) }   // try?-ok: 测试清理
        let primary = FakePrimary(result: Self.primaryResult(engineID: "qwen3"))
        let apples = FakeApple()
        let engine = AppleSecondaryTranscriptionEngine(primary: primary, apples: apples)
        await engine.setRecordingURL(callerURL)

        _ = try await engine.transcribe(Self.request, onPartial: nil)

        let primaryURL = await primary.lastRecordingURL
        #expect(FileManager.default.fileExists(atPath: callerURL.path))
        #expect(primaryURL == callerURL)
    }

    @Test func internallyCreatedRecordingIsDeletedAfterRecognition() async throws {
        let primary = FakePrimary(result: Self.primaryResult(engineID: "qwen3"))
        let apples = FakeApple()
        let engine = AppleSecondaryTranscriptionEngine(primary: primary, apples: apples)

        _ = try await engine.transcribe(Self.request, onPartial: nil)

        let recordedURL = await primary.lastRecordingURL
        let ownedURL = try #require(recordedURL)
        #expect(!FileManager.default.fileExists(atPath: ownedURL.path))
    }

    @Test func primaryFailureSkipsAppleSourcesAndCleansTemporaryAudio() async throws {
        let primary = FakePrimary(result: Self.primaryResult(engineID: "qwen3"),
                                  failure: .unauthorized)
        let apples = FakeApple()
        let engine = AppleSecondaryTranscriptionEngine(primary: primary, apples: apples)

        do {
            _ = try await engine.transcribe(Self.request, onPartial: nil)
            Issue.record("primary failure must propagate")
        } catch {
            #expect(error as? TranscriptionError == .unauthorized)
        }
        let calls = await apples.calls()
        #expect(calls.isEmpty)
        let recordedURL = await primary.lastRecordingURL
        let ownedURL = try #require(recordedURL)
        #expect(!FileManager.default.fileExists(atPath: ownedURL.path))
    }

    @Test func authorizationNotDeterminedSkipsPromptAfterCapture() async throws {
        let primary = FakePrimary(result: Self.primaryResult(engineID: "qwen3"))
        let apples = FakeApple(authorization: .notDetermined)
        let engine = AppleSecondaryTranscriptionEngine(primary: primary, apples: apples)

        let result = try await engine.transcribe(Self.request, onPartial: nil)

        let authorizationRequests = await apples.authorizationRequests()
        let calls = await apples.calls()
        #expect(authorizationRequests == 0)
        #expect(calls.isEmpty)
        #expect(result.text == "primary")
        #expect(result.hypotheses.map(\.engineID) == ["qwen3"])
    }

    @Test func slowAppleSourceIsBoundedByDeadlineAndDoesNotDelayPrimary() async throws {
        let primary = FakePrimary(result: Self.primaryResult(engineID: "qwen3"))
        let apples = FakeApple(delaySeconds: 1)
        let engine = AppleSecondaryTranscriptionEngine(primary: primary, apples: apples,
                                                       appleDeadlineSeconds: 0.05)

        let result = try await engine.transcribe(Self.request, onPartial: nil)

        #expect(result.text == "primary")
        #expect(result.hypotheses.map(\.engineID) == ["qwen3"])
        // 不认壁钟上界（ci-lessons 抖动族）：断言截止真的取消了各副源。
        let cancelled = await apples.cancelledCalls()
        #expect(cancelled.count == 2)
    }

    @Test func failedAppleSourceDoesNotAffectPrimaryDelivery() async throws {
        let primary = FakePrimary(result: Self.primaryResult(engineID: "qwen3"))
        let apples = FakeApple(failAll: true)
        let engine = AppleSecondaryTranscriptionEngine(primary: primary, apples: apples)

        let result = try await engine.transcribe(Self.request, onPartial: nil)

        #expect(result.text == "primary")
        #expect(result.confidence == 0.9)
        #expect(result.hypotheses.map(\.engineID) == ["qwen3"])
    }

    private static func primaryResult(engineID: String, locale: String = "zh-Hans-CN") -> TranscriptionResult {
        TranscriptionResult(
            text: "primary", confidence: 0.9, resolvedLocale: locale, segmented: false,
            completion: .final, engineID: engineID,
            hypotheses: [TranscriptionHypothesis(engineID: engineID, localeIdentifier: locale,
                                                 text: "primary")])
    }
}

// MARK: - Fakes

private actor Signal {
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSet { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func set() {
        isSet = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor FakePrimary: TranscriptionEngine, TranscriptionCaptureReporting, TranscriptionAudioRecording {
    nonisolated let capability: TranscriptionCapability = .baseline(locales: ["zh-Hans-CN", "en-US"])
    let started = Signal()
    let release = Signal()
    private(set) var lastRecordingURL: URL?
    private var recordingURL: URL?
    private let result: TranscriptionResult
    private let failure: TranscriptionError?
    private let waitForRelease: Bool

    init(result: TranscriptionResult, failure: TranscriptionError? = nil,
         waitForRelease: Bool = false) {
        self.result = result
        self.failure = failure
        self.waitForRelease = waitForRelease
    }

    func setRecordingURL(_ url: URL?) async {
        recordingURL = url
        lastRecordingURL = url
    }

    func transcribe(_ request: TranscriptionRequest,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
        try await transcribe(request, onPartial: onPartial, onCaptureStarted: {})
    }

    func transcribe(_ request: TranscriptionRequest, onPartial: (@Sendable (String) -> Void)?,
                    onCaptureStarted: @escaping @Sendable () -> Void) async throws -> TranscriptionResult {
        onCaptureStarted()
        await started.set()
        if waitForRelease { await release.wait() }
        if let failure { throw failure }
        if let recordingURL {
            try Data("primary-audio".utf8).write(to: recordingURL)
        }
        return result
    }

    func finish(sessionID: UUID) async {}
    func cancel(sessionID: UUID) async {}
    func discardSession(sessionID: UUID) async {}
    func endAudio() async {}
}

private actor FakeApple: ASRAppleSourceRunning {
    private var facts: ASRAppleSourceAvailabilityFacts
    private var callsStorage: [ASRAppleSource] = []
    private var authorizationRequestCount = 0
    private var cancelledStorage: [ASRAppleSource] = []
    private let failAll: Bool
    private let delaySeconds: Double

    init(authorization: ASRAppleAuthorization = .authorized, failAll: Bool = false,
         delaySeconds: Double = 0) {
        self.facts = ASRAppleSourceAvailabilityFacts(
            authorization: authorization,
            recognizerAvailableLocales: ["zh-CN", "en-US"],
            onDeviceCapableLocales: ["zh-CN", "en-US"])
        self.failAll = failAll
        self.delaySeconds = delaySeconds
    }

    func availability() async -> ASRAppleSourceAvailabilityFacts { facts }

    func requestAuthorization() async -> ASRAppleAuthorization {
        authorizationRequestCount += 1
        facts.authorization = .authorized
        return .authorized
    }

    func transcribe(audioURL: URL, source: ASRAppleSource,
                    contextualStrings: [String]) async -> ASRAppleSourceResult {
        callsStorage.append(source)
        if delaySeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))   // try?-ok: 超时测试
            if Task.isCancelled {
                cancelledStorage.append(source)
                return .failed(source, reason: "cancelled")
            }
        }
        if failAll {
            return .failed(source, reason: "test-failure")
        }
        return ASRAppleSourceResult(
            source: source, status: .recognized,
            hypothesis: TranscriptionHypothesis(engineID: source.engineID,
                                                localeIdentifier: source.localeIdentifier,
                                                text: "apple-\(source.localeIdentifier)"))
    }

    func calls() -> [ASRAppleSource] { callsStorage }
    func cancelledCalls() -> [ASRAppleSource] { cancelledStorage }
    func authorizationRequests() -> Int { authorizationRequestCount }
}
