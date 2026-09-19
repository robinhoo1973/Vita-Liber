#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import Domain
import ZIPFoundation

/// ASR 模型包解压（结构轮 2026-09-15 自 ASRModelDownloadService 拆出）：
/// ZIPFoundation 解压 + 路径穿越防御（绝对路径/`..`/符号链接/控制字符/重名折叠）+
/// 条目数与展开量上限 + 扩展名白名单 + CRC 校验。单一职责：**只做「zip → 目录」的安全转换**。
enum ModelPackageUnpacker {
    static let fileManager = FileManager.default

    /// `onProgress`: (已解压字节, 预计总字节)。**按条目发**，天然有界
    /// （条目数 ≤ `ModelResourcePolicy.zipEntries`）。
    ///
    /// 2026-09-16 业主实测「进度条无反应、然后突然完成」：解压在 GB 级包上要数十秒，
    /// 此前完全不报进度，界面只能转不确定 spinner——用户读到的就是「不动，然后突然结束」。
    static func unzip(_ zipURL: URL, to root: URL, maximumBytes: Int64,
                      onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) throws {
        let archive = try Archive(url: zipURL, accessMode: .read, pathEncoding: nil)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var paths = Set<String>()
        var count = 0
        var total: UInt64 = 0
        /// 进度分母：遍历中央目录（不解压），廉价。
        let expectedTotal = archive.reduce(UInt64(0)) { $0 + UInt64($1.uncompressedSize) }
        var unpacked: UInt64 = 0
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
            var wroteFile = false
            do {
                if entry.type == .directory {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }
                let ext = target.pathExtension.lowercased()
                guard ["onnx", "json", "txt", "md", "vocab"].contains(ext)
                        || ["LICENSE", "README", "NOTICE"].contains(target.lastPathComponent) else { throw ASRModelDownloadService.Failure.unzipFailed }
                guard fileManager.createFile(atPath: target.path, contents: nil) else { throw ASRModelDownloadService.Failure.unzipFailed }
                wroteFile = true
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
                unpacked += UInt64(entry.uncompressedSize)
                onProgress?(Int64(unpacked), Int64(expectedTotal))
            } catch {
                // 拒绝包不留残件（攻击矩阵 TC）：CRC / 展开量不符只能在**写盘后**才判定得出，
                // 故失败路径必须自清已写入的半成品——否则残留文件留在目标目录（CI 35051860601
                // 实证：篡改包被拒后 `model.onnx` 仍在）。句柄关闭由上方 defer 承担，且 defer 在
                // 作用域因 throw 退出时先于本 catch 执行，此处删除是安全的。只删 `wroteFile`
                // 标记过的路径——目录条目与被白名单挡下的条目从未创建文件，不得误删。
                if wroteFile { try? fileManager.removeItem(at: target) } // try?-ok: 失败路径清理，无用户可见后果
                if error is CancellationError { throw error }
                throw ASRModelDownloadService.Failure.unzipFailed
            }
        }
        guard total == UInt64(maximumBytes) else { throw ASRModelDownloadService.Failure.sizeMismatch }
    }
}
#endif
