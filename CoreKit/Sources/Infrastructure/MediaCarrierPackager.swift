#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：ZIPFoundation 仅 iOS/macOS 链接（Package.swift ERR#8 纪律），Linux 编译空单元，改动须经 macOS CI 验证）
import Foundation
import ZIPFoundation
import Domain
import Protocols

/// `.vlbm` 媒体载具实现（discussions/2026-10-16-backup-sync-share-design.md §8.5）：
/// 目录容器 = `manifest.json + media/{sha256 前 2}/{sha256}.bin`，内容寻址幂等 + 增量——
/// stage 跳过已在载具的字节（重复备份零复制）；import 逐 sha256 校验落盘
/// `originals/{sha256 前 2}/{sha256}.bin`（已在库 → alreadyPresent，绝不复写）。
/// 清单哈希 = **明文原件哈希语义**（加密在信封层承担，载具字节为密文 blob、清单仍为明文哈希）。
public actor MediaCarrierPackager: MediaPackaging {

    public static let manifestFileName = "manifest.json"
    private static let mimeDefault = "application/octet-stream"

    private let originalsRoot: URL
    private let stagingRoot: URL
    private let hasher: any ContentHashing
    private let fileManager: FileManager
    private var stagedEntries: [MediaManifestEntry] = []

    public init(originalsRoot: URL, stagingRoot: URL,
                hasher: any ContentHashing = CryptoKitContentHasher(),
                fileManager: FileManager = .default) {
        self.originalsRoot = originalsRoot
        self.stagingRoot = stagingRoot
        self.hasher = hasher
        self.fileManager = fileManager
    }

    private func mediaRelativePath(_ sha256: String) -> String {
        "media/\(sha256.prefix(2))/\(sha256).bin"
    }

    private func validateSHA(_ sha256: String) throws {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }) else {
            throw MediaPackagingError.sourceMissing(sha256)
        }
    }

    /// 暂存一个原件 blob：载具已含 → nil（零复制）；原件库缺失 → sourceMissing（绝不打包不存在字节）。
    public func stage(sha256: String) async throws -> URL? {
        try validateSHA(sha256)
        let stagingURL = stagingRoot.appendingPathComponent(mediaRelativePath(sha256))
        if fileManager.fileExists(atPath: stagingURL.path) { return nil }
        let source = originalsRoot.appendingPathComponent(mediaRelativePath(sha256))
        guard fileManager.fileExists(atPath: source.path) else {
            throw MediaPackagingError.sourceMissing(sha256)
        }
        try fileManager.createDirectory(at: stagingURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: stagingURL)
        let size = (try? fileManager.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        stagedEntries.append(MediaManifestEntry(sha256: sha256, size: size, mime: Self.mimeDefault))
        return stagingURL
    }

    public func commit(to carrierURL: URL) async throws -> MediaManifest {
        let manifest = MediaManifest(entries: stagedEntries.sorted { $0.sha256 < $1.sha256 })
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
        for entry in manifest.entries {
            try archive.addEntry(with: mediaRelativePath(entry.sha256), relativeTo: stagingRoot, compressionMethod: .deflate)
        }
        return manifest
    }

    public func importMedia(_ carrier: URL) async throws -> MediaImportReport {
        guard let archive = Archive(url: carrier, accessMode: .read) else {
            throw MediaPackagingError.carrierCorrupt
        }
        guard let manifestEntry = archive[Self.manifestFileName] else {
            throw MediaPackagingError.carrierCorrupt
        }
        let manifestData: Data
        do {
            manifestData = try archive.extract(manifestEntry)
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
            throw MediaPackagingError.carrierCorrupt
        }
        var report = MediaImportReport()
        for entry in manifest.entries {
            let path = mediaRelativePath(entry.sha256)
            // zip-slip 防御：路径由 sha 构造（十六进制前缀），任何不符即拒绝
            guard !path.contains(".."), !path.hasPrefix("/"), archive[path] != nil else {
                report.missing.append(entry.sha256)
                continue
            }
            let tempURL = stagingRoot.appendingPathComponent("import-\(UUID().uuidString).bin")
            do {
                try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
                try archive.extract(archive[path]!, to: tempURL)
                let data = try Data(contentsOf: tempURL)
                guard hasher.sha256Hex(data) == entry.sha256 else {
                    report.missing.append(entry.sha256)
                    try? fileManager.removeItem(at: tempURL)
                    continue
                }
                let destination = originalsRoot.appendingPathComponent(path)
                if fileManager.fileExists(atPath: destination.path) {
                    report.alreadyPresent += 1
                } else {
                    try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
                    try fileManager.copyItem(at: tempURL, to: destination)
                    report.imported += 1
                }
                try? fileManager.removeItem(at: tempURL)
            } catch {
                report.missing.append(entry.sha256)
                try? fileManager.removeItem(at: tempURL)
            }
        }
        return report
    }
}
#endif
