import Foundation
import Testing
@testable import Domain

/// 真实签名目录回归（2026-10-19 委员会 P0-④）：生产数据面 = 仓库随包
/// `Resources/ASRModelUpdates/manifest.json`（签名信封）。测试解码**真件**而非
/// 手写夹具——夹具与真目录曾不同构（10 条选型断言 8 条为假，测试席实测）。
/// 签名验证（CryptoKit）在 macOS `ModelCatalogTrustStore` 与 asr-models 发布前
/// verify 承担；此处只做结构与选择契约回归（Linux 可跑）。
@Suite("FR17.15 真实签名目录回归")
struct ASRCatalogRealFixtureTests {
    /// 仓库根 Resources/ASRModelUpdates/manifest.json——#filePath 上溯三级。
    private static var realManifestURL: URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }   // CoreKitTests → Tests → CoreKit → 仓库根
        url.appendPathComponent("Resources/ASRModelUpdates/manifest.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func realIndex() throws -> ASRModelReleaseIndex {
        let url = try #require(realManifestURL, "随包签名目录缺失——Resources/ASRModelUpdates/manifest.json")
        let envelope = try JSONDecoder().decode(SignedModelEnvelope.self, from: Data(contentsOf: url))
        let catalog = try JSONDecoder().decode(SignedModelCatalog.self, from: envelope.payload)
        return catalog.index
    }

    /// 真目录可解码 + families 段在位 + 家族序首位为 zipformer（v10/v11 均不删
    /// zipformer——删它会改变 zh/en 路由与旧 App 下载面，全量退役拆 v12）。
    @Test func realCatalogDecodesWithZipformerFirst() throws {
        let index = try Self.realIndex()
        let families = try #require(index.families)
        #expect(!families.isEmpty)
        #expect(families.first?.id == "zipformer", "auto 链首位家族")
        // 家族 id 必须可解析为随包引擎档——否则 descriptors 静默跳过（fail-open 面）。
        for family in families {
            #expect(VoiceEngineChoice(rawValue: family.id)?.isBundledModel == true,
                    "家族 id 不可解析为随包档: \(family.id)")
        }
    }

    /// P0-① 不变量（选择面）：目录声明的任何语言/方言，auto 选择落到随包档时，
    /// 该档必须**可表达**该 locale（canExpress）——「可路由≠可解码」缺陷族关闭。
    /// v10 下 de/ja/ko/yue 等 qwen3 声明但名称表不可表达的 locale 必须跳过 qwen3。
    @Test func routableLocaleIsDecodableAcrossRealCatalog() throws {
        let index = try Self.realIndex()
        let descriptors = ASRModelCatalog.descriptors(from: index)
        let locales = Set(descriptors.flatMap(\.languageCodes))          // "de"/"fr"/"ja"…
            .union(descriptors.flatMap(\.dialectLocales))                // "yue-Hant-HK"…
            .union(["zh-Hans-CN", "en-US"])                              // 产品两语
        for locale in locales {
            let choice = ASRModelCatalog.automaticChoice(locale: locale, in: index)
            guard choice.isBundledModel else { continue }                // classic/平台轨合法
            let model = try #require(ASRModelCatalog.model(for: choice, in: index))
            #expect(model.canExpress(locale: locale, mode: .single),
                    "auto 选中的随包档必须可表达 \(locale)（选中 \(choice.rawValue)）")
        }
    }

    /// 产品两语在真目录下的稳定路由：zh/en 单语 + 中英混说 → zipformer（首位覆盖），
    /// 且单语可表达。v11 最小收窄不改此断言。
    @Test func productLocalesRouteStablyOnRealCatalog() throws {
        let index = try Self.realIndex()
        #expect(ASRModelCatalog.automaticChoice(locale: "zh-Hans-CN", in: index) == .zipformer)
        #expect(ASRModelCatalog.automaticChoice(locale: "en-US", in: index) == .zipformer)
        #expect(ASRModelCatalog.automaticChoice(locales: ["zh-Hans-CN", "en-US"], in: index) == .zipformer)
        let zipformer = try #require(ASRModelCatalog.model(for: .zipformer, in: index))
        #expect(zipformer.canExpress(locale: "zh-Hans-CN", mode: .single))
        #expect(zipformer.canExpress(locale: "en-US", mode: .single))
    }

    /// 语言面收敛：语言选择器 = 产品两语种，真目录 extras（qwen3 30 语声明等）
    /// 绝不注入选项（V4.26 口径）。
    @Test func catalogExtrasDoNotExpandInputOptions() throws {
        let index = try Self.realIndex()
        let options = EngineCapabilityProfile.inputLanguageOptions(choice: .auto, index: index)
        #expect(options.map(\.locale) == ["zh-Hans-CN", "en-US"])
    }
}
