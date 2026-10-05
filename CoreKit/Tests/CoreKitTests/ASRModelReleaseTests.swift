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
}
