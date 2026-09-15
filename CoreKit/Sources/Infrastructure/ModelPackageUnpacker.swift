#if os(iOS) || os(macOS)
import Foundation
import Domain
import ZIPFoundation

/// ASR 模型包解压（结构轮 2026-09-15 自 ASRModelDownloadService 拆出）：
/// ZIPFoundation 解压 + 路径穿越防御（绝对路径/`..`/符号链接/控制字符/重名折叠）+
/// 条目数与展开量上限 + 扩展名白名单 + CRC 校验。单一职责：**只做「zip → 目录」的安全转换**。
enum ModelPackageUnpacker {
    static let fileManager = FileManager.default

    static func unzip(_ zipURL: URL, to root: URL, maximumBytes: Int64) throws {
        let archive = try Archive(url: zipURL, accessMode: .read, pathEncoding: nil)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var paths = Set<String>()
        var count = 0
        var total: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            // 路径穿越防护：拒绝绝对路径与 `..`（zip 内路径不可信）。
            guard count <= ModelResourcePolicy.zipEntries, entry.type != .symlink,
                  !entry.path.hasPrefix("/"), !entry.path.contains("\\"), !entry.path.contains(":"),
                  !entry.path.split(separator: "/").contains(".."), entry.path.utf8.count <= 1024,
                  !entry.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  UInt64(entry.uncompressedSize) <= UInt64(maximumBytes) - total else {
                throw ASRModelDownloadService.Failure.unzipFailed
            }
            total += UInt64(entry.uncompressedSize)
            let target = root.appendingPathComponent(entry.path).standardizedFileURL
            guard target.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  paths.insert(target.path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw ASRModelDownloadService.Failure.unzipFailed }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            do {
                if entry.type == .directory {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }
                let ext = target.pathExtension.lowercased()
                guard ["onnx", "json", "txt", "md", "vocab"].contains(ext)
                        || ["LICENSE", "README", "NOTICE"].contains(target.lastPathComponent) else { throw ASRModelDownloadService.Failure.unzipFailed }
                guard fileManager.createFile(atPath: target.path, contents: nil) else { throw ASRModelDownloadService.Failure.unzipFailed }
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() } // try?-ok: 解压临时文件句柄关闭
                var received: UInt64 = 0
                let crc = try archive.extract(entry) { data in
                    try Task.checkCancellation()
                    received += UInt64(data.count)
                    guard received <= UInt64(entry.uncompressedSize) else { throw ASRModelDownloadService.Failure.unzipFailed }
                    try handle.write(contentsOf: data)
                }
                guard received == UInt64(entry.uncompressedSize), crc == entry.checksum else { throw ASRModelDownloadService.Failure.unzipFailed }
            } catch {
                if error is CancellationError { throw error }
                throw ASRModelDownloadService.Failure.unzipFailed
            }
        }
        guard total == UInt64(maximumBytes) else { throw ASRModelDownloadService.Failure.sizeMismatch }
    }
}
#endif
