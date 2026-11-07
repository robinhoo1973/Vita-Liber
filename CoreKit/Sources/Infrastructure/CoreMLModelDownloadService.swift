#if os(iOS) || os(macOS)
// linux-blind: URLSession/ZIPFoundation（Apple 平台） —— Linux 空编译单元；行为须经 macOS CI
import Foundation
import ZIPFoundation
import Domain
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Core ML 模型包的显式下载与安装（2026-11-07 业主：下载模型优先于随包）。
///
/// 红线：**只由显式用户动作调用**；无启动检查、无后台刷新、无遥测。
/// 流程：HTTPS 下载 → 字节数/sha256 校验 → 安全解压（路径穿越/条目数/展开量上限）
/// → `CoreMLModelInstallation.install` 原子替换。失败不改变现有生效模型。
public actor CoreMLModelDownloadService {
    public enum Failure: Error, Sendable {
        case downloadFailed
        case sizeMismatch
        case hashMismatch
        case unzipFailed
        case invalidPackage
    }

    public static let maximumBytes: Int64 = 120 * 1_024 * 1_024
    public static let maximumEntries = 2_000

    public init() {}

    public func downloadAndInstall(from url: URL, expectedSHA256: String,
                                   expectedBytes: Int) async throws {
        guard url.scheme?.lowercased() == "https" else { throw Failure.downloadFailed }
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path),   // try?-ok: 取不到尺寸=失败
              let size = attributes[.size] as? NSNumber,
              size.int64Value == Int64(expectedBytes), size.int64Value <= Self.maximumBytes
        else { throw Failure.sizeMismatch }
        let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
        guard data.count == expectedBytes else { throw Failure.sizeMismatch }
        let digest = await Self.sha256Hex(data)
        guard digest == expectedSHA256.lowercased() else { throw Failure.hashMismatch }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreml-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }   // try?-ok: 临时目录清理失败不影响结果
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("model.zip")
        try FileManager.default.moveItem(at: temporary, to: archiveURL)
        let unpacked = root.appendingPathComponent("package", isDirectory: true)
        try unzip(archiveURL, to: unpacked)
        // 允许 zip 根目录直接含 catalog.json，或单一顶层目录包裹。
        let package = try locatePackage(in: unpacked)
        do {
            try CoreMLModelInstallation.install(package: package)
        } catch {
            throw Failure.invalidPackage
        }
    }

    private func locatePackage(in root: URL) throws -> URL {
        let direct = root.appendingPathComponent("catalog.json")
        if FileManager.default.fileExists(atPath: direct.path) { return root }
        let children = (try? FileManager.default.contentsOfDirectory(at: root,   // try?-ok: 空目录=失败
                                                                     includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let directories = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }   // try?-ok: 判定失败=忽略
        guard directories.count == 1,
              FileManager.default.fileExists(atPath: directories[0].appendingPathComponent("catalog.json").path)
        else { throw Failure.unzipFailed }
        return directories[0]
    }

    private func unzip(_ archiveURL: URL, to root: URL) throws {
        let archive = try Archive(url: archiveURL, accessMode: .read, pathEncoding: nil)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var entries = 0
        var total: Int64 = 0
        var seen = Set<String>()
        for entry in archive {
            entries += 1
            total += Int64(entry.uncompressedSize)
            guard entries <= Self.maximumEntries, total <= Self.maximumBytes,
                  entry.type != .symlink, !entry.path.hasPrefix("/"),
                  !entry.path.contains("\\"), !entry.path.contains(":"),
                  !entry.path.split(separator: "/").contains(".."),
                  !entry.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw Failure.unzipFailed }
            let target = root.appendingPathComponent(entry.path).standardizedFileURL
            guard target.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  seen.insert(target.path.precomposedStringWithCanonicalMapping.lowercased()).inserted
            else { throw Failure.unzipFailed }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if entry.type == .directory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw Failure.unzipFailed }
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }   // try?-ok: 临时句柄关闭失败不影响结果
            _ = try archive.extract(entry) { data in try handle.write(contentsOf: data) }
        }
    }

    private static func sha256Hex(_ data: Data) async -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }
}
#endif
