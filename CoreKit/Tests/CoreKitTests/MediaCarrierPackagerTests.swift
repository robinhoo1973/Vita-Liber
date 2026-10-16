import Foundation
import Testing
#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：ZIPFoundation 仅 iOS/macOS 链接，本套件仅 macOS CI 执行）
import ZIPFoundation
@testable import Infrastructure
@testable import Domain
@testable import Protocols

/// `.vlbm` 媒体载具（discussions/2026-10-16-local-storage-layout-council.md §8 切片 9，macOS CI）。
/// 覆盖：加密往返/零复制 stage/源缺/哈希不符/空清单/暂存缺失/敏感路由/篡改字节/
/// 清单级 zip-slip/版本拒绝/跨会话 commit/恶意多余 zip 条目忽略。
struct MediaCarrierPackagerTests {

    private let shaA = String(repeating: "a", count: 64)
    private let shaB = String(repeating: "b", count: 64)

    private func makeTempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlbm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 运行时布局落一个原件：`originals/{sha2}/{sha}.bin`。
    private func makeBlob(in mediaBase: URL, sha: String, bytes: [UInt8]) throws {
        let url = mediaBase.appendingPathComponent(MediaDestinationRules.originalRelativePath(sha256: sha))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    private func makeSealing() throws -> any MediaBlobSealing {
        try CryptoKitMediaBlobSealing(masterKey: Data(repeating: 0x42, count: 32))
    }

    private func originalEntry(sha: String, size: Int64) -> MediaManifestEntry {
        MediaManifestEntry(sha256: sha, size: size, mime: "image/jpeg",
                           relativePath: MediaDestinationRules.originalRelativePath(sha256: sha),
                           isSensitive: false, kind: .original)
    }

    @Test func stageCommitImportEncryptedRoundTrip() async throws {
        let mediaBase = try makeTempDir("originals")
        let staging = try makeTempDir("staging")
        let restore = try makeTempDir("restore")
        let sealing = try makeSealing()
        try makeBlob(in: mediaBase, sha: shaA, bytes: [1, 2, 3])
        try makeBlob(in: mediaBase, sha: shaB, bytes: [4, 5, 6, 7])

        let packager = MediaCarrierPackager(mediaBase: mediaBase, stagingRoot: staging, sealing: sealing)
        let entryA = originalEntry(sha: shaA, size: 3)
        let entryB = originalEntry(sha: shaB, size: 4)
        #expect(try await packager.stage(sourceURL: mediaBase.appendingPathComponent(
            MediaDestinationRules.originalRelativePath(sha256: shaA)), entry: entryA) != nil)
        #expect(try await packager.stage(sourceURL: mediaBase.appendingPathComponent(
            MediaDestinationRules.originalRelativePath(sha256: shaA)), entry: entryA) == nil)  // 已暂存 → 零复制
        #expect(try await packager.stage(sourceURL: mediaBase.appendingPathComponent(
            MediaDestinationRules.originalRelativePath(sha256: shaB)), entry: entryB) != nil)

        // 载具内只存密文：staging 字节 ≠ 明文原件
        let stagedBytes = try Data(contentsOf: staging.appendingPathComponent(
            MediaDestinationRules.carrierRelativePath(sha256: shaA)))
        #expect(stagedBytes != Data([1, 2, 3]))

        let carrier = staging.deletingLastPathComponent().appendingPathComponent("test.vlbm")
        let manifest = try await packager.commit(to: carrier, entries: [entryA, entryB])
        #expect(manifest.entries.count == 2)
        #expect(manifest.schemaVersion == 2)

        let importer = MediaCarrierPackager(mediaBase: restore, stagingRoot: staging, sealing: sealing)
        let report = try await importer.importMedia(carrier)
        #expect(report.imported == 2)
        #expect(report.alreadyPresent == 0)
        #expect(report.missing.isEmpty)
        let restored = restore.appendingPathComponent(MediaDestinationRules.originalRelativePath(sha256: shaA))
        #expect(FileManager.default.fileExists(atPath: restored.path))
        #expect(try Data(contentsOf: restored) == Data([1, 2, 3]))   // 明文逐字节还原

        // 二次导入 → alreadyPresent（幂等，字节零改写）
        let again = try await importer.importMedia(carrier)
        #expect(again.imported == 0)
        #expect(again.alreadyPresent == 2)
    }

    @Test func stageMissingSourceRejected() async throws {
        let mediaBase = try makeTempDir("originals")
        let staging = try makeTempDir("staging")
        let packager = MediaCarrierPackager(mediaBase: mediaBase, stagingRoot: staging, sealing: try makeSealing())
        let entry = originalEntry(sha: shaA, size: 3)
        await #expect(throws: MediaPackagingError.sourceMissing(shaA)) {
            _ = try await packager.stage(sourceURL: mediaBase.appendingPathComponent("nonexistent"), entry: entry)
        }
    }

    @Test func stageShaMismatchRejected() async throws {
        let mediaBase = try makeTempDir("originals")
        let staging = try makeTempDir("staging")
        let packager = MediaCarrierPackager(mediaBase: mediaBase, stagingRoot: staging, sealing: try makeSealing())
        try makeBlob(in: mediaBase, sha: shaA, bytes: [9, 9, 9])   // 源字节哈希 ≠ 条目 sha
        let entry = originalEntry(sha: shaA, size: 3)
        await #expect(throws: MediaPackagingError.shaMismatch(shaA)) {
            _ = try await packager.stage(sourceURL: mediaBase.appendingPathComponent(
                MediaDestinationRules.originalRelativePath(sha256: shaA)), entry: entry)
        }
    }

    @Test func commitEmptyManifestRejected() async throws {
        let staging = try makeTempDir("staging")
        let packager = MediaCarrierPackager(mediaBase: staging, stagingRoot: staging, sealing: try makeSealing())
        let carrier = staging.appendingPathComponent("empty.vlbm")
        await #expect(throws: MediaPackagingError.emptyManifest) {
            _ = try await packager.commit(to: carrier, entries: [])
        }
    }

    @Test func commitStagingIncompleteRejected() async throws {
        let staging = try makeTempDir("staging")
        let packager = MediaCarrierPackager(mediaBase: staging, stagingRoot: staging, sealing: try makeSealing())
        let carrier = staging.appendingPathComponent("lost.vlbm")
        // 从未 stage → commit 必须拒绝（跨会话丢条目防线：绝不产出「清单声称而载具无字节」的包）
        await #expect(throws: MediaPackagingError.stagingIncomplete(shaA)) {
            _ = try await packager.commit(to: carrier, entries: [originalEntry(sha: shaA, size: 3)])
        }
    }

    @Test func crossSessionCommitWorksWithExplicitEntries() async throws {
        let mediaBase = try makeTempDir("originals")
        let staging = try makeTempDir("staging")
        let restore = try makeTempDir("restore")
        let sealing = try makeSealing()
        try makeBlob(in: mediaBase, sha: shaA, bytes: [7, 8])
        let entry = originalEntry(sha: shaA, size: 2)

        let packagerA = MediaCarrierPackager(mediaBase: mediaBase, stagingRoot: staging, sealing: sealing)
        _ = try await packagerA.stage(sourceURL: mediaBase.appendingPathComponent(
            MediaDestinationRules.originalRelativePath(sha256: shaA)), entry: entry)

        // 新实例（模拟进程重启）——entries 显式传入，清单不依赖内存态
        let packagerB = MediaCarrierPackager(mediaBase: mediaBase, stagingRoot: staging, sealing: sealing)
        let carrier = staging.deletingLastPathComponent().appendingPathComponent("session.vlbm")
        let manifest = try await packagerB.commit(to: carrier, entries: [entry])
        #expect(manifest.entries == [entry])

        let importer = MediaCarrierPackager(mediaBase: restore, stagingRoot: staging, sealing: sealing)
        let report = try await importer.importMedia(carrier)
        #expect(report.imported == 1)
        #expect(report.missing.isEmpty)
    }

    @Test func importSensitiveRoutesToMemberDir() async throws {
        let mediaBase = try makeTempDir("originals")
        let staging = try makeTempDir("staging")
        let restore = try makeTempDir("restore")
        let sealing = try makeSealing()
        let member = UUID()
        try makeBlob(in: mediaBase, sha: shaA, bytes: [1, 1, 1])
        let sensitiveEntry = MediaManifestEntry(
            sha256: shaA, size: 3, mime: "image/jpeg",
            relativePath: MediaDestinationRules.sensitiveOriginalRelativePath(memberId: member, sha256: shaA),
            isSensitive: true, memberId: member, kind: .original)

        let packager = MediaCarrierPackager(mediaBase: mediaBase, stagingRoot: staging, sealing: sealing)
        _ = try await packager.stage(sourceURL: mediaBase.appendingPathComponent(
            MediaDestinationRules.originalRelativePath(sha256: shaA)), entry: sensitiveEntry)
        let carrier = staging.deletingLastPathComponent().appendingPathComponent("sensitive.vlbm")
        _ = try await packager.commit(to: carrier, entries: [sensitiveEntry])

        let importer = MediaCarrierPackager(mediaBase: restore, stagingRoot: staging, sealing: sealing)
        let report = try await importer.importMedia(carrier)
        #expect(report.imported == 1)
        let dest = restore.appendingPathComponent(
            MediaDestinationRules.sensitiveOriginalRelativePath(memberId: member, sha256: shaA))
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(!FileManager.default.fileExists(atPath: restore.appendingPathComponent(
            MediaDestinationRules.originalRelativePath(sha256: shaA)).path))   // 敏感件绝不落非敏感路径
    }

    @Test func importTamperedBlobReportedMissing() async throws {
        let mediaBase = try makeTempDir("originals")
        let staging = try makeTempDir("staging")
        let restore = try makeTempDir("restore")
        let sealing = try makeSealing()
        try makeBlob(in: mediaBase, sha: shaA, bytes: [5, 5, 5])
        let entry = originalEntry(sha: shaA, size: 3)

        let packager = MediaCarrierPackager(mediaBase: mediaBase, stagingRoot: staging, sealing: sealing)
        _ = try await packager.stage(sourceURL: mediaBase.appendingPathComponent(
            MediaDestinationRules.originalRelativePath(sha256: shaA)), entry: entry)
        // 篡改暂存密文（模拟载具内字节被改/错钥同效）
        let stagedURL = staging.appendingPathComponent(MediaDestinationRules.carrierRelativePath(sha256: shaA))
        var tampered = try Data(contentsOf: stagedURL)
        tampered[tampered.count - 1] ^= 0xFF
        try tampered.write(to: stagedURL)
        let carrier = staging.deletingLastPathComponent().appendingPathComponent("tampered.vlbm")
        _ = try await packager.commit(to: carrier, entries: [entry])

        let importer = MediaCarrierPackager(mediaBase: restore, stagingRoot: staging, sealing: sealing)
        let report = try await importer.importMedia(carrier)
        #expect(report.imported == 0)
        #expect(report.missing == [shaA])   // 绝不伪造恢复
        #expect(!FileManager.default.fileExists(atPath: restore.appendingPathComponent(
            MediaDestinationRules.originalRelativePath(sha256: shaA)).path))
    }

    @Test func importTraversalManifestEntryMissing() async throws {
        let mediaBase = try makeTempDir("originals")
        let staging = try makeTempDir("staging")
        let restore = try makeTempDir("restore")
        let sealing = try makeSealing()
        try makeBlob(in: mediaBase, sha: shaA, bytes: [3, 3, 3])

        // 清单级 zip-slip：relativePath 带 `..`，而 zip 内 media/{sha2}/{sha}.bin 字节正常在位——
        // 规范形校验必须先于任何落盘动作拒绝。
        let evilEntry = MediaManifestEntry(sha256: shaA, size: 2, mime: "image/jpeg",
                                           relativePath: "../evil.bin", isSensitive: false, kind: .original)
        let packager = MediaCarrierPackager(mediaBase: mediaBase, stagingRoot: staging, sealing: sealing)
        // stage 侧即拒绝（三入口共用 validate）
        await #expect(throws: MediaPackagingError.entryTraversal("../evil.bin")) {
            _ = try await packager.stage(sourceURL: mediaBase.appendingPathComponent(
                MediaDestinationRules.originalRelativePath(sha256: shaA)), entry: evilEntry)
        }

        // 直接构造含恶意清单的载具：正常 stage 后手工改写 manifest.json
        let goodEntry = originalEntry(sha: shaA, size: 2)
        _ = try await packager.stage(sourceURL: mediaBase.appendingPathComponent(
            MediaDestinationRules.originalRelativePath(sha256: shaA)), entry: goodEntry)
        let carrier = staging.deletingLastPathComponent().appendingPathComponent("evil.vlbm")
        _ = try await packager.commit(to: carrier, entries: [goodEntry])
        let evilManifest = MediaManifest(entries: [evilEntry])
        guard let archive = Archive(url: carrier, accessMode: .update) else {
            Issue.record("archive update failed"); return
        }
        let manifestURL = staging.appendingPathComponent(MediaCarrierPackager.manifestFileName)
        try JSONEncoder().encode(evilManifest).write(to: manifestURL, options: .atomic)
        try archive.addEntry(with: MediaCarrierPackager.manifestFileName, relativeTo: staging,
                             compressionMethod: .deflate)

        let importer = MediaCarrierPackager(mediaBase: restore, stagingRoot: staging, sealing: sealing)
        let report = try await importer.importMedia(carrier)
        #expect(report.imported == 0)
        #expect(report.missing == [shaA])   // 恶意条目拒绝，绝不在库外落盘
        #expect(!FileManager.default.fileExists(atPath: restore.deletingLastPathComponent()
            .appendingPathComponent("evil.bin").path))
    }

    @Test func rogueExtraZipEntriesIgnored() async throws {
        let mediaBase = try makeTempDir("originals")
        let staging = try makeTempDir("staging")
        let restore = try makeTempDir("restore")
        let sealing = try makeSealing()
        try makeBlob(in: mediaBase, sha: shaA, bytes: [2, 2])
        let entry = originalEntry(sha: shaA, size: 2)
        let packager = MediaCarrierPackager(mediaBase: mediaBase, stagingRoot: staging, sealing: sealing)
        _ = try await packager.stage(sourceURL: mediaBase.appendingPathComponent(
            MediaDestinationRules.originalRelativePath(sha256: shaA)), entry: entry)
        let carrier = staging.deletingLastPathComponent().appendingPathComponent("rogue.vlbm")
        _ = try await packager.commit(to: carrier, entries: [entry])
        // 追加多余条目（攻击者注入）——import 只读 manifest 与按 sha 构造的条目，绝不遍历提取其余条目
        guard let archive = Archive(url: carrier, accessMode: .update) else {
            Issue.record("archive update failed"); return
        }
        let rogueFile = staging.appendingPathComponent("rogue.txt")
        try Data("evil".utf8).write(to: rogueFile)
        try archive.addEntry(with: "rogue.txt", relativeTo: staging, compressionMethod: .deflate)

        let importer = MediaCarrierPackager(mediaBase: restore, stagingRoot: staging, sealing: sealing)
        let report = try await importer.importMedia(carrier)
        #expect(report.imported == 1)
        #expect(!FileManager.default.fileExists(atPath: restore.appendingPathComponent("rogue.txt").path))
    }

    @Test func unsupportedManifestVersionRejected() async throws {
        let staging = try makeTempDir("staging")
        let carrier = staging.appendingPathComponent("old.vlbm")
        let manifest = MediaManifest(entries: [originalEntry(sha: shaA, size: 1)], schemaVersion: 1)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent(
            MediaCarrierPackager.manifestFileName), options: .atomic)
        guard let archive = Archive(url: carrier, accessMode: .create) else {
            Issue.record("archive create failed"); return
        }
        try archive.addEntry(with: MediaCarrierPackager.manifestFileName, relativeTo: staging,
                             compressionMethod: .deflate)

        let importer = MediaCarrierPackager(mediaBase: staging, stagingRoot: staging, sealing: try makeSealing())
        await #expect(throws: MediaPackagingError.unsupportedManifestVersion(1)) {
            _ = try await importer.importMedia(carrier)
        }
    }
}
#endif
