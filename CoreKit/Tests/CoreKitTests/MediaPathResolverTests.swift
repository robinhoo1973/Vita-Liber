import Foundation
import Testing
@testable import Domain

/// 媒体读取路径解析（discussions/2026-10-16-local-storage-layout-council.md §7.1/Q5，Linux 可跑）。
/// 双形态读：新写相对路径 → sha 推导 CAS → legacy 绝对路径（末位兜底）。
struct MediaPathResolverTests {

    private let sha = String(repeating: "ab", count: 32)
    private let member = UUID()

    @Test func newRelativePathWins() {
        let stored = MediaDestinationRules.sensitiveOriginalRelativePath(memberId: member, sha256: sha)
        // 敏感件：相对路径优先于 sha 推导（sha 推导只给 originals/，对敏感件是错误候选）
        let candidates = MediaPathResolver.candidates(storedPath: stored, originalSha256: sha)
        #expect(candidates == [stored])
    }

    @Test func shaDerivationFillsMissingStoredPath() {
        let candidates = MediaPathResolver.candidates(storedPath: nil, originalSha256: sha)
        #expect(candidates == [MediaDestinationRules.originalRelativePath(sha256: sha)])
    }

    @Test func legacyAbsolutePathIsLastResort() {
        let legacy = "/var/mobile/Containers/Data/Application/dead-uuid/Documents/MedicalNotes/originals/x/y.png"
        let candidates = MediaPathResolver.candidates(storedPath: legacy, originalSha256: sha)
        #expect(candidates == [MediaDestinationRules.originalRelativePath(sha256: sha), legacy])
    }

    @Test func legacyAbsoluteOnly() {
        let legacy = "/var/mobile/Containers/Data/Application/dead-uuid/Documents/MedicalNotes/originals/x/y.png"
        let candidates = MediaPathResolver.candidates(storedPath: legacy, originalSha256: nil)
        #expect(candidates == [legacy])
    }

    @Test func allEmptyGivesNoCandidates() {
        #expect(MediaPathResolver.candidates(storedPath: nil, originalSha256: nil).isEmpty)
        // 非规范形哈希（大写/前缀）不产生推导候选——single canonical form 纪律
        #expect(MediaPathResolver.candidates(storedPath: nil, originalSha256: sha.uppercased()).isEmpty)
        #expect(MediaPathResolver.candidates(storedPath: nil, originalSha256: "sha:\(sha)").isEmpty)
    }

    @Test func relativeAndShaDedup() {
        let derived = MediaDestinationRules.originalRelativePath(sha256: sha)
        let candidates = MediaPathResolver.candidates(storedPath: derived, originalSha256: sha)
        #expect(candidates == [derived])   // 相对路径与 sha 推导同值 → 去重
    }
}
