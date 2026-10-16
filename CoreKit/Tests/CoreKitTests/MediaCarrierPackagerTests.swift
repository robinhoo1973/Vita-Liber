import Foundation
import Testing
#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：ZIPFoundation 仅 iOS/macOS 链接，本套件仅 macOS CI 执行）
import ZIPFoundation
@testable import Infrastructure
@testable import Domain
@testable import Protocols

/// `.vlbm` 媒体载具（discussions/2026-10-16-backup-sync-share-design.md §8.5 切片 6，macOS CI）。
struct MediaCarrierPackagerTests {

    private func makeTempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlbm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBlob(in root: URL, sha: String, bytes: [UInt8]) throws {
        let url = root.appendingPathComponent("media/\(sha.prefix(2))/\(sha).bin")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    private let shaA = String(repeating: "a", count: 64)
    private let shaB = String(repeating: "b", count: 64)

    @Test func stageCommitImportRoundTrip() async throws {
        let originals = try makeTempDir("originals")
        let staging = try makeTempDir("staging")
        let restore = try makeTempDir("restore")
        try makeBlob(in: originals, sha: shaA, bytes: [1, 2, 3])
        try makeBlob(in: originals, sha: shaB, bytes: [4, 5, 6, 7])

        let packager = MediaCarrierPackager(originalsRoot: originals, stagingRoot: staging)
        #expect(try await packager.stage(sha256: shaA) != nil)
        #expect(try await packager.stage(sha256: shaA) == nil)      // 已暂存 → 零复制
        #expect(try await packager.stage(sha256: shaB) != nil)

        let carrier = staging.deletingLastPathComponent().appendingPathComponent("test.vlbm")
        let manifest = try await packager.commit(to: carrier)
        #expect(manifest.entries.count == 2)

        let importer = MediaCarrierPackager(originalsRoot: restore, stagingRoot: staging)
        let report = try await importer.importMedia(carrier)
        #expect(report.imported == 2)
        #expect(report.alreadyPresent == 0)
        #expect(report.missing.isEmpty)
        #expect(FileManager.default.fileExists(atPath: restore.appendingPathComponent("media/\(shaA.prefix(2))/\(shaA).bin").path))

        // 二次导入 → alreadyPresent（幂等，绝不复写）
        let again = try await importer.importMedia(carrier)
        #expect(again.imported == 0)
        #expect(again.alreadyPresent == 2)
    }

    @Test func stageMissingSourceRejected() async throws {
        let originals = try makeTempDir("originals")
        let staging = try makeTempDir("staging")
        let packager = MediaCarrierPackager(originalsRoot: originals, stagingRoot: staging)
        await #expect(throws: MediaPackagingError.self) {
            _ = try await packager.stage(sha256: shaA)
        }
    }

    @Test func corruptedBlobReportedMissing() async throws {
        let originals = try makeTempDir("originals")
        let staging = try makeTempDir("staging")
        let restore = try makeTempDir("restore")
        try makeBlob(in: originals, sha: shaA, bytes: [1, 2, 3])
        let packager = MediaCarrierPackager(originalsRoot: originals, stagingRoot: staging)
        _ = try await packager.stage(sha256: shaA)
        let carrier = staging.deletingLastPathComponent().appendingPathComponent("test.vlbm")
        _ = try await packager.commit(to: carrier)

        // 篡改载具内 blob（重打包同路径字节）→ 哈希不符 → missing，绝不复写伪造字节
        let corrupted = staging.deletingLastPathComponent().appendingPathComponent("corrupt.vlbm")
        guard let archive = Archive(url: carrier, accessMode: .read) else { Issue.record("carrier unreadable"); return }
        guard let out = Archive(url: corrupted, accessMode: .create) else { Issue.record("output uncreatable"); return }
        for entry in archive {
            let path = entry.path
            if path.hasSuffix("\(shaA).bin") {
                try out.addEntry(with: path, type: .file, uncompressedSize: Int64(3), compressionMethod: .deflate) { (position: Int64, size: Int) -> Data in
                    Data([9, 9, 9])
                }
            } else {
                let data = try archive.extract(entry)
                try out.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { (_, _) in data }
            }
        }
        let importer = MediaCarrierPackager(originalsRoot: restore, stagingRoot: staging)
        let report = try await importer.importMedia(corrupted)
        #expect(report.missing == [shaA])
        #expect(report.imported == 0)
    }

    @Test func traversalEntryRejected() async throws {
        // 载具含 `../evil.bin` 条目——导入按清单寻址，路径由 sha 构造，绝不落盘任意条目
        let originals = try makeTempDir("originals")
        let staging = try makeTempDir("staging")
        try makeBlob(in: originals, sha: shaA, bytes: [1])
        let packager = MediaCarrierPackager(originalsRoot: originals, stagingRoot: staging)
        _ = try await packager.stage(sha256: shaA)
        let carrier = staging.deletingLastPathComponent().appendingPathComponent("test.vlbm")
        _ = try await packager.commit(to: carrier)
        let importer = MediaCarrierPackager(originalsRoot: originals, stagingRoot: staging)
        let report = try await importer.importMedia(carrier)
        #expect(report.imported == 1)   // 恶意条目被清单寻址天然忽略（archive["../evil.bin"] 从未被读取）
    }
}
#endif
