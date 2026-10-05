import Foundation
import Testing
@testable import Domain

/// FR17.15 下载地址安全约束（安全审查 2026-09-12）：
/// 索引 `url` 只允许纯相对路径（主机恒等于 baseUrl 主机），baseUrl 必须 https。
@Suite("FR17.15 下载地址安全约束")
struct ASRModelReleaseTests {
    private let httpsBase = URL(string: "https://github.com/robinhoo1973/Vita-Liber/releases/download/asr-models")!

    private func release(url: String) -> ASRModelRelease {
        ASRModelRelease(id: "qwen3", version: "0.6b-int8-v2026.03.25",
                        bytes: 1, sha256: String(repeating: "a", count: 64), url: url)
    }

    /// 原名：绝对URL一律拒绝
    @Test func absoluteURLsAreRejected() {
        #expect(release(url: "https://evil.example.com/x.zip").resolvedURL(baseURL: httpsBase) == nil)
        #expect(release(url: "https:evil.example.com/x.zip").resolvedURL(baseURL: httpsBase) == nil)
        #expect(release(url: "ftp://evil.example.com/x.zip").resolvedURL(baseURL: httpsBase) == nil)
    }

    /// 原名：协议相对URL一律拒绝
    @Test func protocolRelativeURLsAreRejected() {
        #expect(release(url: "//evil.example.com/x.zip").resolvedURL(baseURL: httpsBase) == nil)
    }

    /// 原名：非HTTPS或缺失基准一律拒绝
    @Test func nonHTTPSOrMissingBaseIsRejected() {
        let relative = release(url: "qwen3.zip")
        #expect(relative.resolvedURL(baseURL: URL(string: "http://github.com/x")!) == nil)
        #expect(relative.resolvedURL(baseURL: nil) == nil)
    }

    /// 原名：空URL一律拒绝
    @Test func blankURLIsRejected() {
        #expect(release(url: "   ").resolvedURL(baseURL: httpsBase) == nil)
    }

    /// 原名：同版本换档判定（needsInstall 三分支，2026-10-05 委员会补零覆盖）——
    /// 单保留语义下「切换下载」的唯一起搏器。
    private func tieredRelease(version: String, variant: String?) -> ASRModelRelease {
        ASRModelRelease(id: "zipformer", version: version,
                        bytes: 1, sha256: String(repeating: "a", count: 64),
                        url: "zipformer.zip", variant: variant)
    }

    @Test func needsInstallCoversAllThreeBranches() {
        // 未装 → 需要安装
        #expect(tieredRelease(version: "2023-02-20", variant: "large")
            .needsInstall(installedVersion: nil, installedVariant: nil))
        // 同档新版本 → 需要安装（更新）
        #expect(tieredRelease(version: "2023-03-01", variant: "large")
            .needsInstall(installedVersion: "2023-02-20", installedVariant: "large"))
        // 同版本换档 → 需要安装（切换）
        #expect(tieredRelease(version: "2023-02-20", variant: "large")
            .needsInstall(installedVersion: "2023-02-20", installedVariant: "small"))
        // 同版本同档 → 不需要
        #expect(!tieredRelease(version: "2023-02-20", variant: "large")
            .needsInstall(installedVersion: "2023-02-20", installedVariant: "large"))
        // 已装版本更新 → 不需要
        #expect(!tieredRelease(version: "2023-02-16", variant: "large")
            .needsInstall(installedVersion: "2023-02-20", installedVariant: "large"))
        // 无 variant 键的单档条目：同版本同档（nil==nil）→ 不需要
        #expect(!tieredRelease(version: "2023-02-20", variant: nil)
            .needsInstall(installedVersion: "2023-02-20", installedVariant: nil))
    }

    /// 原名：相对路径解析到基准主机且补齐尾斜杠
    @Test func relativePathResolvesToBaseHostWithTrailingSlash() {
        let resolved = release(url: "qwen3-0.6b-int8-v2026.03.25-20260912.zip").resolvedURL(baseURL: httpsBase)
        #expect(resolved?.absoluteString
                == "https://github.com/robinhoo1973/Vita-Liber/releases/download/asr-models/qwen3-0.6b-int8-v2026.03.25-20260912.zip")
        #expect(resolved?.host == httpsBase.host)
        #expect(resolved?.scheme == "https")
    }

    /// 档位权重按体积升序（2026-10-05 iOS 适用性评估后扩档）：
    /// tiny<base<small<medium<turbo<large，未知/缺失排末尾。
    @Test func variantWeightOrdersBySizeNotLexicographic() {
        let ordered = ["tiny", "base", "small", "medium", "turbo", "large"]
        let weights = ordered.map { ASRModelRelease.variantWeight($0) }
        #expect(weights == [0, 1, 2, 3, 4, 5])
        #expect(ASRModelRelease.variantWeight(nil) > ASRModelRelease.variantWeight("large"))
        #expect(ASRModelRelease.variantWeight("gigantic") > ASRModelRelease.variantWeight("large"))
    }
}

/// 目录本地化文案与家族条目（2026-10-05 业主裁定：模型文字描述由 CI 目录 JSON 提供）。
@Suite("目录文案 schema")
struct ASRCatalogTextTests {
    /// 首选语言解析：繁体系→zh-Hant；简体/其他 zh→zh-Hans；en→en；
    /// 缺首选语言时按 zh-Hans→zh-Hant→en 兜底。
    @Test func localizedTextResolvesByPreferredLanguage() {
        let text = ASRLocalizedText(zhHans: "简体", zhHant: "繁體", en: "English")
        #expect(text.resolved(preferredLanguages: ["zh-Hant-TW", "en"]) == "繁體")
        #expect(text.resolved(preferredLanguages: ["zh-HK", "en"]) == "繁體")
        #expect(text.resolved(preferredLanguages: ["zh-Hans-CN"]) == "简体")
        #expect(text.resolved(preferredLanguages: ["zh", "en"]) == "简体")
        #expect(text.resolved(preferredLanguages: ["en-US"]) == "English")
        #expect(text.resolved(preferredLanguages: ["fr-FR"]) == "简体")
        #expect(ASRLocalizedText(zhHant: "繁體").resolved(preferredLanguages: ["fr"]) == "繁體")
        #expect(ASRLocalizedText().resolved(preferredLanguages: ["fr"]) == nil)
    }

    /// 索引解码：families/tierName/tierHint 三语键；旧目录缺字段 → nil/空，零回归。
    @Test func indexDecodesFamiliesAndTierTextsWithLegacyFallback() throws {
        let json = """
        {
          "schemaVersion": 1,
          "baseUrl": "https://cnb.cool/robinhoo1973/Resources/-/releases/download/asr-models",
          "families": [
            {"id": "whisper", "name": {"zh-Hans": "Whisper · 多语种", "en": "Whisper · Multilingual"},
             "hint": {"zh-Hans": "多语外语识别"}}
          ],
          "models": [
            {"id": "whisper", "variant": "turbo", "version": "2024-09-30", "bytes": 1,
             "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
             "url": "whisper-turbo.zip",
             "tierName": {"zh-Hans": "高速", "zh-Hant": "高速", "en": "Turbo"},
             "tierHint": {"zh-Hans": "质量接近大档、速度快约两倍"}}
          ]
        }
        """
        let index = try JSONDecoder().decode(ASRModelReleaseIndex.self, from: Data(json.utf8))
        #expect(index.families?.first?.id == "whisper")
        #expect(index.family(for: "whisper")?.name?.resolved(preferredLanguages: ["zh-Hans"]) == "Whisper · 多语种")
        let turbo = index.models.first { $0.variant == "turbo" }
        #expect(turbo?.tierName?.resolved(preferredLanguages: ["en"]) == "Turbo")
        #expect(turbo?.tierHint?.resolved(preferredLanguages: ["zh-Hans"]) == "质量接近大档、速度快约两倍")
        #expect(turbo?.tierHint?.resolved(preferredLanguages: ["en"]) == "质量接近大档、速度快约两倍")
        #expect(turbo?.tierHint?.resolved(preferredLanguages: ["fr"]) == "质量接近大档、速度快约两倍")

        let legacy = """
        {
          "schemaVersion": 1,
          "models": [
            {"id": "qwen3", "version": "0.6b", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
             "url": "qwen3.zip"}
          ]
        }
        """
        let old = try JSONDecoder().decode(ASRModelReleaseIndex.self, from: Data(legacy.utf8))
        #expect(old.families == nil)
        #expect(old.family(for: "qwen3") == nil)
        #expect(old.models.first?.tierName == nil)
        #expect(old.models.first?.tierHint == nil)
    }
}
