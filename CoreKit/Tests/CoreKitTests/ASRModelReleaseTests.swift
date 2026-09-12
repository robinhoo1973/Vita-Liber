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

    @Test func 绝对URL一律拒绝() {
        #expect(release(url: "https://evil.example.com/x.zip").resolvedURL(baseURL: httpsBase) == nil)
        #expect(release(url: "https:evil.example.com/x.zip").resolvedURL(baseURL: httpsBase) == nil)
        #expect(release(url: "ftp://evil.example.com/x.zip").resolvedURL(baseURL: httpsBase) == nil)
    }

    @Test func 协议相对URL一律拒绝() {
        #expect(release(url: "//evil.example.com/x.zip").resolvedURL(baseURL: httpsBase) == nil)
    }

    @Test func 非HTTPS或缺失基准一律拒绝() {
        let relative = release(url: "qwen3.zip")
        #expect(relative.resolvedURL(baseURL: URL(string: "http://github.com/x")!) == nil)
        #expect(relative.resolvedURL(baseURL: nil) == nil)
    }

    @Test func 空URL一律拒绝() {
        #expect(release(url: "   ").resolvedURL(baseURL: httpsBase) == nil)
    }

    @Test func 相对路径解析到基准主机且补齐尾斜杠() {
        let resolved = release(url: "qwen3-0.6b-int8-v2026.03.25-20260912.zip").resolvedURL(baseURL: httpsBase)
        #expect(resolved?.absoluteString
                == "https://github.com/robinhoo1973/Vita-Liber/releases/download/asr-models/qwen3-0.6b-int8-v2026.03.25-20260912.zip")
        #expect(resolved?.host == httpsBase.host)
        #expect(resolved?.scheme == "https")
    }
}
