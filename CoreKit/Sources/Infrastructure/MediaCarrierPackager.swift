#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：ZIPFoundation 仅 iOS/macOS 链接（Package.swift ERR#8 纪律），Linux 编译空单元，改动须经 macOS CI 验证）
import Foundation
import ZIPFoundation
import Domain
import Protocols

/// `.vlbm` 媒体载具实现（discussions/2026-10-16-local-storage-layout-council.md §8 切片 9）：
/// 载具 = `manifest.json + media/{sha256 前 2}/{sha256}.bin`（zip 内路径），内容寻址幂等 + 增量——
/// stage 跳过已在载具的字节（重复备份零复制）；import 逐条目解密 + 明文哈希校验后按
/// entry.relativePath 落盘（非敏感 originals/{sha2}/{sha}.bin；敏感 sensitive/{memberId}/…
/// + .completeFileProtection），已在库 → alreadyPresent（绝不复写）。
/// 清单哈希 = **明文原件哈希语义**（哈希=防损坏；防篡改由 AES-GCM 承担；加密不改清单哈希）。
/// zip-slip 防御：条目路径由 MediaDestinationRules 规范形校验（文档条目重算比对），
/// 只读取 manifest 与按 sha 构造的 zip 条目，绝不遍历提取其余条目。
public actor MediaCarrierPackager: MediaPackaging {

    public static let manifestFileName = "manifest.json"

    private let mediaBase: URL      // 运行时落盘根（Documents/MedicalNotes；测试注入临时目录）
    private let stagingRoot: URL    // 载具暂存目录（Caches/tmp——不进 Documents 明文）
    private let hasher: any ContentHashing
    private let sealing: any MediaBlobSealing
    private let fileManager: FileManager

    public init(mediaBase: URL, stagingRoot: URL, sealing: any MediaBlobSealing,
                hasher: any ContentHashing = CryptoKitContentHasher(),
                fileManager: FileManager = .default) {
        self.mediaBase = mediaBase
        self.stagingRoot = stagingRoot
        self.hasher = hasher
        self.sealing = sealing
        self.fileManager = fileManager
    }

    /// 暂存一个原件 blob：读源 → 校验明文哈希与 entry.sha256 一致 → 加密 → 写入 staging。
    /// 载具已含同 sha → nil（零复制）；源缺失 → sourceMissing；哈希不符 → shaMismatch（绝不打包错字节）。
    public func stage(sourceURL: URL, entry: MediaManifestEntry) async throws -> URL? {
        try validate(entry)
        let stagedURL = stagedBlobURL(entry.sha256)
        if fileManager.fileExists(atPath: stagedURL.path) { return nil }
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw MediaPackagingError.sourceMissing(entry.sha256)
        }
        let plain = try Data(contentsOf: sourceURL)
        guard hasher.sha256Hex(plain) == entry.sha256 else {
            throw MediaPackagingError.shaMismatch(entry.sha256)
        }
        let sealed = try sealing.seal(plain)
        try fileManager.createDirectory(at: stagedURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let partial = URL(fileURLWithPath: stagedURL.path + ".partial")
        try sealed.write(to: partial, options: .atomic)
        try fileManager.moveItem(at: partial, to: stagedURL)
        return stagedURL
    }

    /// 收尾载具：entries 由调用方显式传入（跨会话安全——stagedEntries 内存态缺陷的修复），
    /// 空清单拒绝；每个条目的暂存字节必须在位（staging 缺失 → stagingIncomplete，绝不产出缺字节清单）。
    public func commit(to carrierURL: URL, entries: [MediaManifestEntry]) async throws -> MediaManifest {
        guard !entries.isEmpty else { throw MediaPackagingError.emptyManifest }
        for entry in entries {
            try validate(entry)
            guard fileManager.fileExists(atPath: stagedBlobURL(entry.sha256).path) else {
                throw MediaPackagingError.stagingIncomplete(entry.sha256)
            }
        }
        let sorted = entries.sorted { $0.sha256 < $1.sha256 }
        let manifest = MediaManifest(entries: sorted)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let manifestURL = stagingRoot.appendingPathComponent(Self.manifestFileName)
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        if fileManager.fileExists(atPath: carrierURL.path) {
            try fileManager.removeItem(at: carrierURL)
        }
        guard let archive = Archive(url: carrierURL, accessMode: .create) else {
            throw MediaPackagingError.carrierCorrupt
        }
        try archive.addEntry(with: Self.manifestFileName, relativeTo: stagingRoot, compressionMethod: .deflate)
        for entry in sorted {
            try archive.addEntry(with: MediaDestinationRules.carrierRelativePath(sha256: entry.sha256),
                                 relativeTo: stagingRoot, compressionMethod: .deflate)
        }
        return manifest
    }

    /// 逐条目校验落盘：解压 → 解密 → 明文哈希比对 → 按 entry.relativePath 落盘（敏感 .complete）。
    /// 已在库 → alreadyPresent；缺字节/哈希不符/路径非法 → missing（绝不伪造恢复）。
    public func importMedia(_ carrier: URL) async throws -> MediaImportReport {
        guard let archive = Archive(url: carrier, accessMode: .read) else {
            throw MediaPackagingError.carrierCorrupt
        }
        guard let manifestZipEntry = archive[Self.manifestFileName] else {
            throw MediaPackagingError.carrierCorrupt
        }
        let manifestData: Data
        do {
            manifestData = try archive.extract(manifestZipEntry)
        } catch {
            throw MediaPackagingError.carrierCorrupt
        }
        let manifest: MediaManifest
        do {
            manifest = try JSONDecoder().decode(MediaManifest.self, from: manifestData)
        } catch {
            throw MediaPackagingError.carrierCorrupt
        }
        guard manifest.schemaVersion == MediaManifest.currentSchemaVersion else {
            throw MediaPackagingError.unsupportedManifestVersion(manifest.schemaVersion)
        }
        var report = MediaImportReport()
        for entry in manifest.entries {
            guard MediaDestinationRules.isCanonicalEntry(entry) else {
                report.missing.append(entry.sha256)
                continue
            }
            guard let blobEntry = archive[MediaDestinationRules.carrierRelativePath(sha256: entry.sha256)] else {
                report.missing.append(entry.sha256)
                continue
            }
            do {
                let sealed = try archive.extract(blobEntry)
                let plain = try sealing.open(sealed)
                guard hasher.sha256Hex(plain) == entry.sha256 else {
                    report.missing.append(entry.sha256)
                    continue
                }
                let destination = mediaBase.appendingPathComponent(entry.relativePath)
                if fileManager.fileExists(atPath: destination.path) {
                    report.alreadyPresent += 1
                    continue
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                var options: Data.WritingOptions = [.atomic]
                if entry.isSensitive { options.insert(.completeFileProtection) }
                try plain.write(to: destination, options: options)
                report.imported += 1
            } catch {
                report.missing.append(entry.sha256)
            }
        }
        return report
    }

    private func stagedBlobURL(_ sha256: String) -> URL {
        stagingRoot.appendingPathComponent(MediaDestinationRules.carrierRelativePath(sha256: sha256))
    }

    /// 条目规范形校验（含哈希小写 hex64 与相对路径安全形）——stage/commit/import 三入口共用。
    private func validate(_ entry: MediaManifestEntry) throws {
        guard MediaDestinationRules.isCanonicalEntry(entry) else {
            throw MediaPackagingError.entryTraversal(entry.relativePath)
        }
    }
}
#endif
