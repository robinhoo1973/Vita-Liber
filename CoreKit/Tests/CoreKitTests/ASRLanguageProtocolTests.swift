import Foundation
import Testing
@testable import Domain

/// FR17.15：Qwen3 只认训练分布内的语言名称（Chinese/Cantonese/English…，官方模型卡），
/// 混说/自动模式留空启用模型自带语种识别；whisper 走 ISO 码；其余引擎不接收语言提示。
/// 上游 sherpa 把 "language <值>" 原样编码进解码提示——传 ISO 码等于强制一个训练分布外的标签
/// （2026-09-13 round2 A-N1：方言/外语识别坍缩的直接协议缺陷）。
@Suite("FR17.15 解码语言提示协议")
struct ASRLanguageProtocolTests {
    @Test(arguments: [
        ("zh-Hans-CN", "Chinese"), ("zh-Hant-TW", "Chinese"), ("nan-TW", "Chinese"),
        ("wuu-CN", "Chinese"), ("zh-Hans-CN-Sichuan", "Chinese"),
        ("yue-Hant-HK", "Cantonese"), ("yue-Hans-CN", "Cantonese"),
        ("en-US", "English"), ("ja-JP", "Japanese"), ("fil-PH", "Filipino")
    ])
    /// 原名：Qwen单语模式产出官方语言名称
    func qwenMonolingualModeProducesOfficialLanguageName(_ locale: String, _ expected: String) throws {
        let qwen = try #require(ASRModelCatalog.model(for: .qwen3))
        #expect(qwen.decoderLanguage(for: locale, mode: .single) == expected)
    }

    /// 原名：Qwen混说模式不强制语言以启用自带语种识别
    @Test func qwenMixedModeLeavesLanguageEmptyToEnableBuiltInDetection() throws {
        let qwen = try #require(ASRModelCatalog.model(for: .qwen3))
        #expect(qwen.decoderLanguage(for: "zh-Hans-CN", mode: .mixed) == "")
        #expect(qwen.decoderLanguage(for: "yue-Hant-HK", mode: .mixed) == "")
    }

    /// 原名：不支持的locale返回nil而不是猜测
    @Test func unsupportedLocaleReturnsNilInsteadOfGuessing() throws {
        let zipformer = try #require(ASRModelCatalog.model(for: .zipformer))
        #expect(zipformer.decoderLanguage(for: "yue-Hant-HK", mode: .single) == nil)
        let qwen = try #require(ASRModelCatalog.model(for: .qwen3))
        #expect(qwen.decoderLanguage(for: "xx-ZZ", mode: .single) == nil)
    }

    /// 原名：whisper沿用ISO码且其余引擎为空
    @Test func whisperUsesISOCodeOthersEmpty() throws {
        #expect(try #require(ASRModelCatalog.model(for: .whisper)).decoderLanguage(for: "fr-FR", mode: .single) == "fr")
        #expect(try #require(ASRModelCatalog.model(for: .whisper)).decoderLanguage(for: "fr-FR", mode: .mixed) == "fr")
        #expect(try #require(ASRModelCatalog.model(for: .zipformer)).decoderLanguage(for: "en-US", mode: .single) == "")
        #expect(try #require(ASRModelCatalog.model(for: .dolphin)).decoderLanguage(for: "wuu-CN", mode: .single) == "")
    }

    /// 原名：请求默认单语模式且可显式指定混说
    @Test func requestDefaultsToSingleModeAndMixedCanBeExplicit() {
        #expect(TranscriptionRequest(localeIdentifier: "zh-Hans-CN").languageMode == .single)
        #expect(TranscriptionRequest(localeIdentifier: "zh-Hans-CN", languageMode: .mixed).languageMode == .mixed)
    }

    /// 原名：自动选择让Qwen优先承担英语与外语
    @Test func automaticChoicePrefersQwenForEnglishAndForeign() {
        #expect(ASRModelCatalog.automaticChoice(locale: "en-US") == .qwen3)
        #expect(ASRModelCatalog.automaticChoice(locale: "de-DE") == .qwen3)
        #expect(ASRModelCatalog.automaticChoice(locale: "ur-PK") == .dolphin)
        #expect(ASRModelCatalog.automaticChoice(locale: "la-VA") == .whisper)
    }
}
