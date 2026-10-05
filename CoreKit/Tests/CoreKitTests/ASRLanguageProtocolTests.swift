import Foundation
import Testing
@testable import Domain

/// FR17.15：Qwen3 只认训练分布内的语言名称（Chinese/Cantonese/English…，官方模型卡），
/// 混说/自动模式留空启用模型自带语种识别；whisper 走 ISO 码；其余引擎不接收语言提示。
/// 上游 sherpa 把 "language <值>" 原样编码进解码提示——传 ISO 码等于强制一个训练分布外的标签
/// （2026-09-13 round2 A-N1：方言/外语识别坍缩的直接协议缺陷）。
///
/// 2026-10-05 目录驱动（业主裁定）：语言覆盖/方言覆盖全部来自签名目录 JSON——
/// 本套件用与 CI 模板同构的夹具索引（数据事实源 = `Resources/ASRModels` 模板，
/// 经 ASR 包生成 CI 签发）。
@Suite("FR17.15 解码语言提示协议")
struct ASRLanguageProtocolTests {
    /// 与 CI 模板 families 段同构的测试夹具（优先级 = 发布序）。
    static let fixtureIndex: ASRModelReleaseIndex = ASRModelReleaseIndex(
        baseUrl: "https://cnb.cool/fixture/Resources/-/releases/download/asr-models",
        models: [
            ASRModelRelease(id: "qwen3", version: "0.6B-int8-2026-03-25", bytes: 1,
                            sha256: String(repeating: "a", count: 64), url: "qwen3.zip", license: "Apache-2.0"),
            ASRModelRelease(id: "zipformer", version: "2025-06-30", bytes: 1,
                            sha256: String(repeating: "b", count: 64), url: "zipformer.zip", license: "Apache-2.0"),
            ASRModelRelease(id: "dolphin", version: "small-ctc-int8-2025-04-02", bytes: 1,
                            sha256: String(repeating: "c", count: 64), url: "dolphin.zip", license: "Apache-2.0"),
            ASRModelRelease(id: "whisper", version: "small-int8-2024-07-13", bytes: 1,
                            sha256: String(repeating: "d", count: 64), url: "whisper.zip", license: "MIT"),
        ],
        families: [
            ASRModelFamily(id: "qwen3",
                           languages: "zh en yue ar de fr es pt id it ko ru th vi ja tr hi ms nl sv da fi pl cs fil fa el hu mk ro".split(separator: " ").map(String.init),
                           dialects: ["yue-Hant-HK", "yue-Hans-CN", "nan-TW", "wuu-CN", "zh-Hans-CN-Sichuan"]),
            ASRModelFamily(id: "zipformer", languages: ["zh"]),
            ASRModelFamily(id: "dolphin",
                           languages: "zh ja th ru ko id vi hi ur ms uz ar fa bn ta te ug gu my tl kk or ne mn km jv lo si fil ps pa kab ba ks tg su mr ky az".split(separator: " ").map(String.init),
                           dialects: ["yue-Hant-HK", "yue-Hans-CN", "nan-TW", "wuu-CN", "zh-Hans-CN-Sichuan"]),
            ASRModelFamily(id: "whisper",
                           languages: "en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su".split(separator: " ").map(String.init)),
        ])

    @Test(arguments: [
        ("zh-Hans-CN", "Chinese"), ("zh-Hant-TW", "Chinese"), ("nan-TW", "Chinese"),
        ("wuu-CN", "Chinese"), ("zh-Hans-CN-Sichuan", "Chinese"),
        ("yue-Hant-HK", "Cantonese"), ("yue-Hans-CN", "Cantonese"),
        ("en-US", "English"), ("ja-JP", "Japanese"), ("fil-PH", "Filipino")
    ])
    /// 原名：Qwen单语模式产出官方语言名称
    func qwenMonolingualModeProducesOfficialLanguageName(_ locale: String, _ expected: String) throws {
        let qwen = try #require(ASRModelCatalog.model(for: .qwen3, in: Self.fixtureIndex))
        #expect(qwen.decoderLanguage(for: locale, mode: .single) == expected)
    }

    /// 原名：Qwen混说模式不强制语言以启用自带语种识别
    @Test func qwenMixedModeLeavesLanguageEmptyToEnableBuiltInDetection() throws {
        let qwen = try #require(ASRModelCatalog.model(for: .qwen3, in: Self.fixtureIndex))
        #expect(qwen.decoderLanguage(for: "zh-Hans-CN", mode: .mixed) == "")
        #expect(qwen.decoderLanguage(for: "yue-Hant-HK", mode: .mixed) == "")
    }

    /// 原名：不支持的locale返回nil而不是猜测
    @Test func unsupportedLocaleReturnsNilInsteadOfGuessing() throws {
        let zipformer = try #require(ASRModelCatalog.model(for: .zipformer, in: Self.fixtureIndex))
        #expect(zipformer.decoderLanguage(for: "yue-Hant-HK", mode: .single) == nil)
        #expect(zipformer.decoderLanguage(for: "en-US", mode: .single) == nil)   // zh 2025 家族不含英语
        let qwen = try #require(ASRModelCatalog.model(for: .qwen3, in: Self.fixtureIndex))
        #expect(qwen.decoderLanguage(for: "xx-ZZ", mode: .single) == nil)
    }

    /// 原名：whisper沿用ISO码且其余引擎为空
    /// 2026-10-05 业主反馈修复批（第 7 项）：whisper 混说不再强制主语言——
    /// 空串 = sherpa whisper 自带语种自动检测（合同更新，原断言「混说仍返 ISO 码」随之修订）。
    @Test func whisperUsesISOCodeOthersEmpty() throws {
        #expect(try #require(ASRModelCatalog.model(for: .whisper, in: Self.fixtureIndex)).decoderLanguage(for: "fr-FR", mode: .single) == "fr")
        #expect(try #require(ASRModelCatalog.model(for: .whisper, in: Self.fixtureIndex)).decoderLanguage(for: "fr-FR", mode: .mixed) == "")
        #expect(try #require(ASRModelCatalog.model(for: .zipformer, in: Self.fixtureIndex)).decoderLanguage(for: "zh-Hans-CN", mode: .single) == "")
        #expect(try #require(ASRModelCatalog.model(for: .dolphin, in: Self.fixtureIndex)).decoderLanguage(for: "wuu-CN", mode: .single) == "")
    }

    /// 原名：请求默认单语模式且可显式指定混说
    @Test func requestDefaultsToSingleModeAndMixedCanBeExplicit() {
        #expect(TranscriptionRequest(localeIdentifier: "zh-Hans-CN").languageMode == .single)
        #expect(TranscriptionRequest(localeIdentifier: "zh-Hans-CN", languageMode: .mixed).languageMode == .mixed)
    }

    /// 原名：自动选择让Qwen优先承担英语与外语（目录发布序 = 优先序，CI 所有）
    @Test func automaticChoicePrefersQwenForEnglishAndForeign() {
        #expect(ASRModelCatalog.automaticChoice(locale: "en-US", in: Self.fixtureIndex) == .qwen3)
        #expect(ASRModelCatalog.automaticChoice(locale: "de-DE", in: Self.fixtureIndex) == .qwen3)
        #expect(ASRModelCatalog.automaticChoice(locale: "ur-PK", in: Self.fixtureIndex) == .dolphin)
        #expect(ASRModelCatalog.automaticChoice(locale: "la-VA", in: Self.fixtureIndex) == .whisper)
        // 目录无覆盖/空目录 → classic 零资产基线轨
        #expect(ASRModelCatalog.automaticChoice(locale: "zh-Hans-CN", in: nil) == .classic)
    }
}
