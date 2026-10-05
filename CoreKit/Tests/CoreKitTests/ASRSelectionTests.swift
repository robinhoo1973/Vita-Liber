import Foundation
import Testing
@testable import Domain
@testable import Protocols
@testable import Infrastructure

@Suite("FR17.15 随包模型选择与会话归属")
struct ASRSelectionTests {
    /// 原名：方言不会被当作英语或普通话模型支持
    @Test func dialectsNotOfferedAsEnglishOrMandarinSupport() {
        #expect(ASRModelCatalog.model(for: .dolphin)?.languageCode(for: "wuu-CN") == "zh")
        #expect(ASRModelCatalog.model(for: .dolphin)?.languageCode(for: "en-US") == nil)
        #expect(ASRModelCatalog.model(for: .zipformer)?.languageCode(for: "yue-Hant-HK") == nil)
        #expect(ASRModelCatalog.model(for: .whisper)?.languageCode(for: "yue-Hant-HK") == nil)
        #expect(ASRModelCatalog.model(for: .whisper)?.languageCode(for: "fr-FR") == "fr")
    }

    /// 原名：自动选择依据请求语言而不修改显式选择
    @Test func automaticChoiceFollowsRequestLocaleWithoutOverridingExplicitChoice() {
        #expect(ASRModelCatalog.automaticChoice(locale: "nan-TW") == .qwen3)
        #expect(ASRModelCatalog.automaticChoice(locale: "zh-Hans-CN") == .qwen3)
        // round2 A-N5：完整解码模型优先——英语/外语由 Qwen3 承担，缺件回落在 builder 门控。
        #expect(ASRModelCatalog.automaticChoice(locale: "en-US") == .qwen3)
        #expect(ASRModelCatalog.automaticChoice(locale: "de-DE") == .qwen3)
        #expect(ASRModelCatalog.automaticChoice(locale: "ur-PK") == .dolphin)
        #expect(VoiceEngineChoice.resolve("dolphin") == .dolphin)
        #expect(VoiceEngineChoice.resolve("classic") == .classic)
    }

    /// 2026-10-05 业主反馈修复批（第 7 项）：混说多语种选择——按覆盖**全部**已选语种
    /// 的模型取目录序首个；无全量覆盖回落主语言单语种逻辑。
    @Test func automaticChoiceOverAllSelectedLocales() {
        // qwen3 同时覆盖普通话+英语/粤语+日语 → qwen3
        #expect(ASRModelCatalog.automaticChoice(locales: ["zh-Hans-CN", "en-US"]) == .qwen3)
        #expect(ASRModelCatalog.automaticChoice(locales: ["yue-Hant-HK", "ja-JP"]) == .qwen3)
        // zh+ur：qwen3 不盖 ur、zipformer 不盖 ur → dolphin（亚洲语种 CTC）
        #expect(ASRModelCatalog.automaticChoice(locales: ["zh-Hans-CN", "ur-PK"]) == .dolphin)
        // en+la：qwen3/zipformer/dolphin 均不盖 la → whisper
        #expect(ASRModelCatalog.automaticChoice(locales: ["en-US", "la-VA"]) == .whisper)
        // 单语种特例与旧路径一致；空列表回落 classic（无主语言可依）
        #expect(ASRModelCatalog.automaticChoice(locales: ["zh-Hans-CN"]) == .qwen3)
        #expect(ASRModelCatalog.automaticChoice(locales: []) == .classic)
    }

    /// 2026-10-05 业主反馈修复批（第 7 项）：whisper 混说不再强制主语言——
    /// 空串 = sherpa whisper 自带语种自动检测（此前恒返回 ISO 码，混说开关对 whisper 无效）。
    @Test func whisperMixedModeEnablesAutoDetection() {
        #expect(ASRModelCatalog.model(for: .whisper)?.decoderLanguage(for: "en-US", mode: .mixed) == "")
        #expect(ASRModelCatalog.model(for: .whisper)?.decoderLanguage(for: "en-US", mode: .single) == "en")
        #expect(ASRModelCatalog.model(for: .qwen3)?.decoderLanguage(for: "zh-Hans-CN", mode: .mixed) == "")
        #expect(ASRModelCatalog.model(for: .qwen3)?.decoderLanguage(for: "zh-Hans-CN", mode: .single) == "Chinese")
    }

    /// 2026-10-05 业主反馈修复批（第 7 项）：请求携带全部已选语种（向后兼容默认空）。
    @Test func requestCarriesAdditionalLocalesForMixedSelection() {
        let request = TranscriptionRequest(localeIdentifier: "zh-Hans-CN", languageMode: .mixed,
                                           additionalLocales: ["en-US", "yue-Hant-HK", "zh-Hans-CN"])
        #expect(request.allLocales == ["zh-Hans-CN", "en-US", "yue-Hant-HK"])
        let legacy = TranscriptionRequest(localeIdentifier: "zh-Hans-CN")
        #expect(legacy.allLocales == ["zh-Hans-CN"])
        #expect(legacy.additionalLocales.isEmpty)
    }

    /// 原名：首次建委托前松手不启动识别
    @Test func releaseBeforeDelegateSetupDoesNotStartRecognition() async throws {
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

    /// 原名：首次建委托前取消仍然抛取消而不返回文字
    @Test func cancelBeforeDelegateSetupThrowsCancellationNotText() async {
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

    /// 2026-10-05 业主反馈修复批（第 8 项）：OOM 加载失败自动回落可用模型——
    /// 结果 engineID 由回落引擎自设（诚实性：不冒充所选档）。
    @Test func oomFallbackServesAvailableEngineAndReportsIt() async throws {
        let starts = Starts()
        let engine = SwitchableTranscriptionEngine(
            choiceProvider: { .qwen3 },
            builder: { choice -> any TranscriptionEngine in
                choice == .qwen3 ? FailingMemoryEngine() : ImmediateEngine(starts: starts)
            },
            fallbackResolver: { failed, locale in
                (failed == .qwen3 && locale == "zh-Hans-CN") ? .zipformer : nil
            })
        let request = TranscriptionRequest(localeIdentifier: "zh-Hans-CN")
        let result = try await engine.transcribe(request, onPartial: nil)
        #expect(result.engineID == "zipformer")
        #expect(await starts.value == 1)
    }

    /// 2026-10-05 业主反馈修复批（第 8 项）：无回落候选时抛原错（不吞错、不换冒充）。
    @Test func oomWithoutFallbackThrowsOriginalError() async {
        let engine = SwitchableTranscriptionEngine(
            choiceProvider: { .qwen3 },
            builder: { _ in FailingMemoryEngine() },
            fallbackResolver: { _, _ in nil })
        let request = TranscriptionRequest(localeIdentifier: "zh-Hans-CN")
        do {
            _ = try await engine.transcribe(request, onPartial: nil)
            Issue.record("无回落候选时必须抛原错")
        } catch let error as TranscriptionError {
            #expect(error == .insufficientMemory(requiredBytes: 5, availableBytes: 1))
        } catch {
            Issue.record("错误类型不正确：\(error)")
        }
    }

    /// 2026-10-05 业主反馈修复批（第 8 项）：回落循环不得同档重试（delegate 按 choice
    /// 缓存，同档重试必再抛——解析器返回同档视为无候选）。
    @Test func oomFallbackNeverRetriesSameChoice() async {
        let engine = SwitchableTranscriptionEngine(
            choiceProvider: { .qwen3 },
            builder: { _ in FailingMemoryEngine() },
            fallbackResolver: { failed, _ in failed })   // 恶意解析器：恒返回失败档
        let request = TranscriptionRequest(localeIdentifier: "zh-Hans-CN")
        do {
            _ = try await engine.transcribe(request, onPartial: nil)
            Issue.record("同档重试循环必须被拦截")
        } catch let error as TranscriptionError {
            #expect(error == .insufficientMemory(requiredBytes: 5, availableBytes: 1))
        } catch {
            Issue.record("错误类型不正确：\(error)")
        }
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
    private struct FailingMemoryEngine: TranscriptionEngine {
        var capability: TranscriptionCapability { .baseline() }
        func transcribe(_ request: TranscriptionRequest, onPartial: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
            throw TranscriptionError.insufficientMemory(requiredBytes: 5, availableBytes: 1)
        }
    }
}
