import Foundation
import Testing
@testable import Infrastructure

/// 平台中立（Linux 可跑）：App 本机 anti-rollback floor——只记录已验证 installable
/// 候选达到过的最高 catalogVersion + 规范 pointer 摘要，绝不因安装失败回退。
@Suite("Medical catalog trust store")
struct MedicalCatalogTrustStoreTests {
    private static let digestA = String(repeating: "a", count: 64)
    private static let digestB = String(repeating: "b", count: 64)

    @Test("higher version persists and reloads from a fresh instance")
    func higherVersionPersistsAndReloads() throws {
        let directory = Self.makeDirectory()
        defer { Self.cleanUp(directory) }
        let fileURL = directory.appendingPathComponent("trust-floor.json")

        let store = MedicalCatalogTrustStore(fileURL: fileURL)
        #expect(store.observedFloor == nil)
        try store.acceptVerifiedInstallable(catalogVersion: 30, payloadDigest: Self.digestA)
        #expect(store.observedFloor == .init(catalogVersion: 30, payloadDigest: Self.digestA))

        try store.acceptVerifiedInstallable(catalogVersion: 31, payloadDigest: Self.digestB)
        #expect(store.observedFloor == .init(catalogVersion: 31, payloadDigest: Self.digestB))

        // 全新实例从同一文件重新加载，必须看到相同的已持久化 floor。
        let reloaded = MedicalCatalogTrustStore(fileURL: fileURL)
        #expect(reloaded.observedFloor == .init(catalogVersion: 31, payloadDigest: Self.digestB))
    }

    @Test("lower version is rejected as rollback and does not lower the floor")
    func lowerVersionRejected() throws {
        let directory = Self.makeDirectory()
        defer { Self.cleanUp(directory) }
        let store = MedicalCatalogTrustStore(fileURL: directory.appendingPathComponent("trust-floor.json"))
        try store.acceptVerifiedInstallable(catalogVersion: 30, payloadDigest: Self.digestA)

        #expect(throws: MedicalCatalogTrustStore.Failure.rollback) {
            try store.acceptVerifiedInstallable(catalogVersion: 29, payloadDigest: Self.digestB)
        }
        #expect(store.observedFloor == .init(catalogVersion: 30, payloadDigest: Self.digestA))
    }

    @Test("same version and same canonical pointer digest is an idempotent no-op")
    func sameVersionSameDigestIsIdempotent() throws {
        let directory = Self.makeDirectory()
        defer { Self.cleanUp(directory) }
        let store = MedicalCatalogTrustStore(fileURL: directory.appendingPathComponent("trust-floor.json"))
        try store.acceptVerifiedInstallable(catalogVersion: 30, payloadDigest: Self.digestA)

        try store.acceptVerifiedInstallable(catalogVersion: 30, payloadDigest: Self.digestA)
        #expect(store.observedFloor == .init(catalogVersion: 30, payloadDigest: Self.digestA))
    }

    @Test("same version with a different pointer digest is rejected as equivocation")
    func sameVersionDifferentDigestRejected() throws {
        let directory = Self.makeDirectory()
        defer { Self.cleanUp(directory) }
        let store = MedicalCatalogTrustStore(fileURL: directory.appendingPathComponent("trust-floor.json"))
        try store.acceptVerifiedInstallable(catalogVersion: 30, payloadDigest: Self.digestA)

        #expect(throws: MedicalCatalogTrustStore.Failure.equivocation) {
            try store.acceptVerifiedInstallable(catalogVersion: 30, payloadDigest: Self.digestB)
        }
        #expect(store.observedFloor == .init(catalogVersion: 30, payloadDigest: Self.digestA))
    }

    @Test("progress pointers (installable == false) are rejected by accept(_:) and never reach the floor")
    func progressPointersRejected() throws {
        let directory = Self.makeDirectory()
        defer { Self.cleanUp(directory) }
        let store = MedicalCatalogTrustStore(fileURL: directory.appendingPathComponent("trust-floor.json"))
        let progress = try Self.progressCandidate()

        #expect(throws: MedicalCatalogTrustStore.Failure.notInstallable) {
            try store.accept(progress)
        }
        #expect(store.observedFloor == nil)

        // 即便已有已建立的 floor，后续 progress 候选依然不能改动它。
        try store.acceptVerifiedInstallable(catalogVersion: 30, payloadDigest: Self.digestA)
        #expect(throws: MedicalCatalogTrustStore.Failure.notInstallable) {
            try store.accept(progress)
        }
        #expect(store.observedFloor == .init(catalogVersion: 30, payloadDigest: Self.digestA))
    }

    @Test("installable candidates advance the floor through accept(_:) exactly as through the 2-arg method")
    func acceptForwardsInstallableCandidateToTheFloor() throws {
        let directory = Self.makeDirectory()
        defer { Self.cleanUp(directory) }
        let store = MedicalCatalogTrustStore(fileURL: directory.appendingPathComponent("trust-floor.json"))
        let candidate = try Self.installableCandidate()

        try store.accept(candidate)
        #expect(store.observedFloor == .init(catalogVersion: candidate.catalogVersion,
                                             payloadDigest: candidate.signedPointerDigest))
    }

    @Test("a failed atomic write leaves the prior persisted and in-memory state intact")
    func failedAtomicWriteLeavesPriorStateIntact() throws {
        let directory = Self.makeDirectory()
        defer {
            _ = chmod(directory.path, 0o755) // 恢复权限，保证 cleanUp 能删除目录
            Self.cleanUp(directory)
        }
        let fileURL = directory.appendingPathComponent("trust-floor.json")
        let store = MedicalCatalogTrustStore(fileURL: fileURL)
        try store.acceptVerifiedInstallable(catalogVersion: 30, payloadDigest: Self.digestA)
        let dataBefore = try #require(FileManager.default.contents(atPath: fileURL.path))

        // 目录只读：新临时文件创建/改名会失败，模拟"失败的原子写"。
        #expect(chmod(directory.path, 0o555) == 0)
        #expect(throws: (any Error).self) {
            try store.acceptVerifiedInstallable(catalogVersion: 31, payloadDigest: Self.digestB)
        }
        // 内存态未推进。
        #expect(store.observedFloor == .init(catalogVersion: 30, payloadDigest: Self.digestA))
        // 磁盘上的旧状态原封不动（目录只读，读权限仍在）。
        #expect(FileManager.default.contents(atPath: fileURL.path) == dataBefore)
        _ = chmod(directory.path, 0o755)

        // 一个全新实例重新加载，必须仍看到写入失败前的 floor，而不是更低/缺失。
        let reloaded = MedicalCatalogTrustStore(fileURL: fileURL)
        #expect(reloaded.observedFloor == .init(catalogVersion: 30, payloadDigest: Self.digestA))
    }

    @Test("corrupted or oversized persisted state resets to no floor rather than crashing")
    func corruptedStateResetsRatherThanCrashing() throws {
        let directory = Self.makeDirectory()
        defer { Self.cleanUp(directory) }
        let fileURL = directory.appendingPathComponent("trust-floor.json")
        try Data("not json".utf8).write(to: fileURL)
        let store = MedicalCatalogTrustStore(fileURL: fileURL)
        #expect(store.observedFloor == nil)
        // 仍可从零开始正常推进（不会因为损坏文件而被永久锁死）。
        try store.acceptVerifiedInstallable(catalogVersion: 1, payloadDigest: Self.digestA)
        #expect(store.observedFloor == .init(catalogVersion: 1, payloadDigest: Self.digestA))
    }

    /// 复用 Go 导出金样的 progress pointer（`installable == false`），不手造签名候选。
    private static func progressCandidate() throws -> VerifiedMedicalCatalogCandidate {
        let expected = try GoMedicalFixture.expected()
        let pointer = try GoMedicalFixture.data(expected.progressPointer)
        let expectation = try GoMedicalFixture.expectation(pointer, servedAs: expected.progressPointer)
        return VerifiedMedicalCatalogCandidate(verified: expectation)
    }

    private static func installableCandidate() throws -> VerifiedMedicalCatalogCandidate {
        let expected = try GoMedicalFixture.expected()
        let pointer = try GoMedicalFixture.data(expected.installablePointer)
        let expectation = try GoMedicalFixture.expectation(pointer, servedAs: expected.installablePointer)
        return VerifiedMedicalCatalogCandidate(verified: expectation)
    }

    private static func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("medical-trust-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) // try?-ok: 创建失败由随后的用例断言暴露
        return directory
    }

    private static func cleanUp(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory) // try?-ok: 隔离测试目录清理
    }
}
