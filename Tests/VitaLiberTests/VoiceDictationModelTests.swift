import XCTest
import Foundation
import Domain
import Protocols
@testable import VitaLiber

// binds: SU-M15-VOICE (FR17.1 V3.61 停顿丢字 / FR17.15 主语言与词表)
/// 视图模型半场（App 目标，macOS CI）：旧会话最终文本不因快速重按换代而丢；
/// 语言设置装配主语言与混说词表；实际识别 locale 回显。
@MainActor
final class VoiceDictationModelTests: XCTestCase {
    /// 可控延迟的引擎替身：模拟「松手后 isFinal 稍后到达」
    private actor DelayedEngine: TranscriptionEngine {
        nonisolated let capability = TranscriptionCapability.baseline(locales: ["zh-Hans-CN", "en-US"])
        private let text: String
        private let delayNanos: UInt64
        private(set) var lastRequest: TranscriptionRequest?
        init(text: String, delayNanos: UInt64) { self.text = text; self.delayNanos = delayNanos }
        func transcribe(_ request: TranscriptionRequest,
                        onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
            lastRequest = request
            onPartial?(String(text.prefix(2)))
            try await Task.sleep(nanoseconds: delayNanos)
            return TranscriptionResult(text: text, confidence: 0.9, resolvedLocale: "zh-Hans-CN",
                                       segmented: true, segments: [text])
        }
    }

    func test_previousSessionFinalIsDeliveredAfterQuickRestart() async throws {
        let engine = DelayedEngine(text: "我今天头疼 吃了两片布洛芬", delayNanos: 150_000_000)
        let model = VoiceDictationModel(engine: engine, preferredLocale: "zh-Hans-CN")
        var delivered: [String] = []
        model.onTranscript = { text, _ in delivered.append(text) }
        model.start()
        try await Task.sleep(nanoseconds: 30_000_000)
        model.stop()          // 松手
        model.start()         // 150ms 内快速重按 → 会话换代
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(delivered.first, "我今天头疼 吃了两片布洛芬",
                       "旧会话的最终文本是用户说过的话，不得因换代丢弃（V3.61）")
        XCTAssertEqual(model.resolvedLocale, "zh-Hans-CN")
        XCTAssertFalse(model.isBestEffortFallback)
    }

    func test_languageSettingsBuildPrimaryLocaleAndVocabulary() async throws {
        let engine = DelayedEngine(text: "x", delayNanos: 1)
        let model = VoiceDictationModel(engine: engine)
        model.applyLanguageSettings(storedLocales: "en-US,zh-Hans-CN", mixedInput: true,
                                    recentDrugNames: ["布洛芬", "阿莫西林"])
        XCTAssertEqual(model.preferredLocale, "en-US", "主语言 = 保序首位，不再字母序")
        XCTAssertEqual(Array(model.contextualStrings.prefix(2)), ["布洛芬", "阿莫西林"])
        XCTAssertTrue(model.contextualStrings.contains("mmHg"))
        XCTAssertLessThanOrEqual(model.contextualStrings.count, MixedSpeechVocabulary.limit)
        model.applyLanguageSettings(storedLocales: "zh-Hans-CN", mixedInput: false, recentDrugNames: ["布洛芬"])
        XCTAssertTrue(model.contextualStrings.isEmpty, "混说开关关闭 = 不注入词表")
        model.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        let request = await engine.lastRequest
        XCTAssertEqual(request?.localeIdentifier, "zh-Hans-CN")
        XCTAssertEqual(request?.contextualStrings, [])
    }
}
