import Foundation
#if os(iOS) || os(macOS)
// linux-blind: Darwin 信号/资源 API 仅 Apple 平台，Linux 编译空单元，改动须经 macOS CI 验证
import Darwin
#endif

/// A pool may open a new reader after active-path rename. Keep its filename
/// immutable for the entire pair's lifetime, including suspended reads.
final class MedicalCatalogSnapshotFile: @unchecked Sendable {
    /// 读快照缓存目录名（与活跃路径同目录——硬链接要求同卷，故不可挪到 Caches/）。
    /// 测试夹具的「目录内只许活跃/患者库/last-good」断言须把它列入允许集。
    static let directoryName = ".medical-catalog-read-snapshots"
    let url: URL
    private let owner: FileHandle
    private let ownerURL: URL

    private init(url: URL, owner: FileHandle, ownerURL: URL) {
        self.url = url
        self.owner = owner
        self.ownerURL = ownerURL
    }

    deinit {
        try? FileManager.default.removeItem(at: url) // try?-ok: private read pin cleanup only
        try? FileManager.default.removeItem(at: ownerURL) // try?-ok: private lease cleanup only
        try? owner.close() // try?-ok: best-effort descriptor cleanup during deinitialization
    }

    #if os(iOS) || os(macOS)
    private static let creationLock = NSLock()

    static func pin(_ source: URL) throws -> MedicalCatalogSnapshotFile {
        try creationLock.withLock {
            let files = FileManager.default
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0,
                  Int64(size) <= MedicalCatalogUpdateLimits.standard.maxSQLiteBytes else {
                throw MedicalCatalogUpdateError.catalogIntegrityFailed
            }
            let root = source.deletingLastPathComponent()
                .appendingPathComponent(Self.directoryName, isDirectory: true)
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            removeOrphans(in: root)
            let name = UUID().uuidString
            let url = root.appendingPathComponent(name).appendingPathExtension("sqlite")
            let ownerURL = root.appendingPathComponent(name).appendingPathExtension("lock")
            guard files.createFile(atPath: ownerURL.path, contents: Data()) else {
                throw MedicalCatalogUpdateError.activationFailed
            }
            let owner = try FileHandle(forWritingTo: ownerURL)
            let retained = MedicalCatalogSnapshotFile(url: url, owner: owner, ownerURL: ownerURL)
            guard flock(owner.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw MedicalCatalogUpdateError.activationFailed
            }
            do {
                try files.linkItem(at: source, to: url)
            } catch {
                // Same-directory hard links cost no extra catalog bytes; copy
                // remains correct on filesystems without hard-link support.
                try files.copyItem(at: source, to: url)
            }
            return retained
        }
    }

    private static func removeOrphans(in root: URL) {
        guard let paths = try? FileManager.default.contentsOfDirectory(at: root,   // try?-ok: cache cleanup must not block opening
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for path in paths where path.pathExtension == "sqlite"
            && UUID(uuidString: path.deletingPathExtension().lastPathComponent) != nil {
            guard let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), // try?-ok: ignore unowned/unreadable cache entries
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let ownerURL = path.deletingPathExtension().appendingPathExtension("lock")
            guard let owner = try? FileHandle(forReadingFrom: ownerURL) else { continue } // try?-ok: only collect recognizable expired leases
            defer { try? owner.close() } // try?-ok: best-effort descriptor cleanup
            guard flock(owner.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            try? FileManager.default.removeItem(at: path) // try?-ok: unlocked private orphan pin
            try? FileManager.default.removeItem(at: ownerURL) // try?-ok: unlocked private orphan lease
        }
    }
    #endif
}
