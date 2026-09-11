import Foundation
import Testing
@testable import Domain
@testable import Protocols
@testable import Infrastructure

@Suite("FR17.15 随包模型选择与会话归属")
struct ASRSelectionTests {
    @Test func 方言不会被当作英语或普通话模型支持() {
        #expect(ASRModelCatalog.model(for: .dolphin)?.languageCode(for: "wuu-CN") == "zh")
        #expect(ASRModelCatalog.model(for: .dolphin)?.languageCode(for: "en-US") == nil)
        #expect(ASRModelCatalog.model(for: .zipformer)?.languageCode(for: "yue-Hant-HK") == nil)
        #expect(ASRModelCatalog.model(for: .whisper)?.languageCode(for: "yue-Hant-HK") == nil)
        #expect(ASRModelCatalog.model(for: .whisper)?.languageCode(for: "fr-FR") == "fr")
    }

    @Test func 自动选择依据请求语言而不修改显式选择() {
        #expect(ASRModelCatalog.automaticChoice(locale: "nan-TW") == .qwen3)
        #expect(ASRModelCatalog.automaticChoice(locale: "zh-Hans-CN") == .qwen3)
        #expect(ASRModelCatalog.automaticChoice(locale: "en-US") == .zipformer)
        #expect(ASRModelCatalog.automaticChoice(locale: "de-DE") == .whisper)
        #expect(VoiceEngineChoice.resolve("dolphin") == .dolphin)
        #expect(VoiceEngineChoice.resolve("classic") == .classic)
    }

    @Test func 首次建委托前松手不启动识别() async throws {
        let counter = Starts()
        let engine = SwitchableTranscriptionEngine(choiceProvider: { .classic }, builder: { _ in
            ImmediateEngine(starts: counter)
        })
        let request = TranscriptionRequest(localeIdentifier: "zh-Hans-CN")
        await engine.finish(sessionID: request.sessionID)
        let result = try await engine.transcribe(request, onPartial: nil)
        #expect(result.text.isEmpty)
        #expect(await counter.value == 0)
    }

    @Test func 首次建委托前取消仍然抛取消而不返回文字() async {
        let counter = Starts()
        let engine = SwitchableTranscriptionEngine(choiceProvider: { .classic }, builder: { _ in
            ImmediateEngine(starts: counter)
        })
        let request = TranscriptionRequest(localeIdentifier: "zh-Hans-CN")
        await engine.cancel(sessionID: request.sessionID)
        do {
            _ = try await engine.transcribe(request, onPartial: nil)
            Issue.record("已取消的按压不得识别")
        } catch is CancellationError {} catch { Issue.record("错误类型不正确：\(error)") }
        #expect(await counter.value == 0)
    }

    private actor Starts {
        var value = 0
        func increment() { value += 1 }
    }
    private struct ImmediateEngine: TranscriptionEngine {
        let starts: Starts
        var capability: TranscriptionCapability { .baseline() }
        func transcribe(_ request: TranscriptionRequest, onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
            await starts.increment()
            return .init(text: "不应出现", confidence: 0, resolvedLocale: request.localeIdentifier, segmented: false)
        }
    }
}
