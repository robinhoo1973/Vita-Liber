import Foundation
import Testing
@testable import Domain

/// FR17.15 构建期信任锚——fail closed 语义的回归锚点（安全审查 2026-09-12）：
/// 未登记/哈希不符/字节不符/空表/未知结构版本一律拒绝安装。
@Suite("FR17.15 构建期信任锚")
struct TrustedModelHashesTests {
    private let shaA = String(repeating: "a", count: 64)
    private let shaB = String(repeating: "b", count: 64)

    private func release(sha: String? = nil, bytes: Int64 = 1) -> ASRModelRelease {
        ASRModelRelease(id: "qwen3", version: "0.6b-int8-v2026.03.25",
                        bytes: bytes, sha256: sha ?? shaA, url: "qwen3.zip")
    }

    private var table: TrustedModelHashes {
        TrustedModelHashes(entries: [
            .init(id: "qwen3", version: "0.6b-int8-v2026.03.25", bytes: 1, sha256: shaA)
        ])
    }

    /// 原名：命中锚且一致通过
    @Test func trustedEntryHitAndConsistentPasses() {
        #expect(table.isTrusted(release()))
    }

    /// 原名：未登记版本拒绝
    @Test func unregisteredVersionRejected() {
        #expect(!table.isTrusted(ASRModelRelease(id: "qwen3", version: "9.9", bytes: 1, sha256: shaA, url: "x.zip")))
        #expect(!table.isTrusted(ASRModelRelease(id: "whisper", version: "0.6b-int8-v2026.03.25", bytes: 1, sha256: shaA, url: "x.zip")))
    }

    /// 原名：哈希不一致拒绝
    @Test func hashMismatchRejected() {
        #expect(!table.isTrusted(release(sha: shaB)))
    }

    /// 原名：字节不一致拒绝
    @Test func byteSizeMismatchRejected() {
        #expect(!table.isTrusted(release(bytes: 999)))
    }

    /// 原名：大小写不敏感哈希通过
    @Test func caseInsensitiveHashPasses() {
        #expect(table.isTrusted(release(sha: shaA.uppercased())))
    }

    /// 原名：空表拒绝一切
    @Test func emptyTableRejectsEverything() {
        #expect(!TrustedModelHashes.empty.isTrusted(release()))
    }

    /// 原名：未知结构版本视为空表
    @Test func unknownSchemaVersionTreatedAsEmptyTable() {
        #expect(!TrustedModelHashes(schemaVersion: 99, entries: table.entries).isTrusted(release()))
    }
}
