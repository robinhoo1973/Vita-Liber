import Foundation
import Testing
@testable import Domain

/// 媒体落盘路径规则（discussions/2026-10-16-local-storage-layout-council.md §7.1，Linux 可跑）。
/// 单一路径知识：写/读/备份/恢复/GC/分享六处共享同一套规则——分支表逐分支映射用例。
struct MediaDestinationRulesTests {

    private let sha = String(repeating: "ab", count: 32)          // 64 位小写 hex
    private let member = UUID()

    // MARK: 路径派生

    @Test func originalPathDerivation() {
        #expect(MediaDestinationRules.originalRelativePath(sha256: sha) == "originals/ab/\(sha).bin")
    }

    @Test func carrierPathDerivation() {
        #expect(MediaDestinationRules.carrierRelativePath(sha256: sha) == "media/ab/\(sha).bin")
    }

    @Test func sensitivePathDerivation() {
        #expect(MediaDestinationRules.sensitiveOriginalRelativePath(memberId: member, sha256: sha)
                == "sensitive/\(member.uuidString)/\(sha).bin")
    }

    @Test func photoBlurPathDerivation() {
        let asset = UUID()
        #expect(MediaDestinationRules.photoRelativePath(memberId: member, assetId: asset)
                == "sensitive/\(member.uuidString)/\(asset.uuidString).jpg")
        #expect(MediaDestinationRules.blurRelativePath(memberId: member, assetId: asset)
                == "sensitive/\(member.uuidString)/\(asset.uuidString).blur.jpg")
    }

    // MARK: 哈希规范形（单规范形：小写 hex64）

    @Test func lowercaseHex64Accepted() {
        #expect(MediaDestinationRules.isLowercaseHex64(sha))
        #expect(MediaDestinationRules.isLowercaseHex64(String(repeating: "0", count: 64)))
        #expect(MediaDestinationRules.isLowercaseHex64(String(repeating: "f", count: 64)))
    }

    @Test func hashShapeRejected() {
        #expect(!MediaDestinationRules.isLowercaseHex64(""))                       // 空
        #expect(!MediaDestinationRules.isLowercaseHex64(String(repeating: "a", count: 63)))  // 短
        #expect(!MediaDestinationRules.isLowercaseHex64(String(repeating: "a", count: 65)))  // 长
        #expect(!MediaDestinationRules.isLowercaseHex64(String(repeating: "A", count: 64)))  // 大写
        #expect(!MediaDestinationRules.isLowercaseHex64(sha + "g"))                // 非 hex
        #expect(!MediaDestinationRules.isLowercaseHex64("sha:" + sha))             // 前缀（document_file.sha256 旧形态）
    }

    // MARK: 相对路径安全形（zip-slip 防御）

    @Test func safeRelativePathAccepted() {
        #expect(MediaDestinationRules.isSafeRelativePath("originals/ab/\(sha).bin"))
        #expect(MediaDestinationRules.isSafeRelativePath("sensitive/\(member.uuidString)/\(sha).bin"))
    }

    @Test func traversalRejected() {
        #expect(!MediaDestinationRules.isSafeRelativePath(""))                    // 空
        #expect(!MediaDestinationRules.isSafeRelativePath("/etc/passwd"))         // 绝对路径
        #expect(!MediaDestinationRules.isSafeRelativePath("../evil.bin"))         // .. 前缀
        #expect(!MediaDestinationRules.isSafeRelativePath("originals/ab/../evil")) // .. 分量
        #expect(!MediaDestinationRules.isSafeRelativePath("originals//ab/x.bin")) // 空分量
        #expect(!MediaDestinationRules.isSafeRelativePath("a/./b"))               // . 分量
        #expect(!MediaDestinationRules.isSafeRelativePath("originals/ab/x.bin.partial")) // 写盘中形态
    }

    // MARK: 条目规范形（落盘前必过）

    private func entry(kind: MediaKind, sensitive: Bool, memberId: UUID?, path: String) -> MediaManifestEntry {
        MediaManifestEntry(sha256: sha, size: 1, mime: "image/jpeg", relativePath: path,
                           isSensitive: sensitive, memberId: memberId, kind: kind)
    }

    @Test func canonicalOriginalAccepted() {
        #expect(MediaDestinationRules.isCanonicalEntry(
            entry(kind: .original, sensitive: false, memberId: nil,
                  path: MediaDestinationRules.originalRelativePath(sha256: sha))))
    }

    @Test func canonicalSensitiveOriginalAccepted() {
        #expect(MediaDestinationRules.isCanonicalEntry(
            entry(kind: .original, sensitive: true, memberId: member,
                  path: MediaDestinationRules.sensitiveOriginalRelativePath(memberId: member, sha256: sha))))
    }

    @Test func mismatchedEntryRejected() {
        // 非敏感条目却指向敏感目录
        #expect(!MediaDestinationRules.isCanonicalEntry(
            entry(kind: .original, sensitive: false, memberId: nil,
                  path: MediaDestinationRules.sensitiveOriginalRelativePath(memberId: member, sha256: sha))))
        // 敏感条目却指向 originals/
        #expect(!MediaDestinationRules.isCanonicalEntry(
            entry(kind: .original, sensitive: true, memberId: member,
                  path: MediaDestinationRules.originalRelativePath(sha256: sha))))
        // 敏感条目缺 memberId
        #expect(!MediaDestinationRules.isCanonicalEntry(
            entry(kind: .original, sensitive: true, memberId: nil,
                  path: MediaDestinationRules.sensitiveOriginalRelativePath(memberId: member, sha256: sha))))
        // 路径带 ..（zip-slip）
        #expect(!MediaDestinationRules.isCanonicalEntry(
            entry(kind: .original, sensitive: false, memberId: nil,
                  path: "../originals/ab/\(sha).bin")))
        // 大写哈希（非规范形）
        #expect(!MediaDestinationRules.isCanonicalEntry(
            entry(kind: .original, sensitive: false, memberId: nil,
                  path: MediaDestinationRules.originalRelativePath(sha256: sha.uppercased()))))
    }

    @Test func photoShapeAcceptedAndRejected() {
        let asset = UUID()
        #expect(MediaDestinationRules.isCanonicalEntry(MediaManifestEntry(
            sha256: sha, size: 1, mime: "image/jpeg",
            relativePath: MediaDestinationRules.photoRelativePath(memberId: member, assetId: asset),
            isSensitive: true, memberId: member, kind: .photo)))
        // 照片条目 memberId 与路径 memberId 不符 → 拒
        #expect(!MediaDestinationRules.isCanonicalEntry(MediaManifestEntry(
            sha256: sha, size: 1, mime: "image/jpeg",
            relativePath: MediaDestinationRules.photoRelativePath(memberId: UUID(), assetId: asset),
            isSensitive: true, memberId: member, kind: .photo)))
        // 照片条目非敏感标记 → 拒（F8 照片恒敏感）
        #expect(!MediaDestinationRules.isCanonicalEntry(MediaManifestEntry(
            sha256: sha, size: 1, mime: "image/jpeg",
            relativePath: MediaDestinationRules.photoRelativePath(memberId: member, assetId: asset),
            isSensitive: false, memberId: member, kind: .photo)))
    }
}
