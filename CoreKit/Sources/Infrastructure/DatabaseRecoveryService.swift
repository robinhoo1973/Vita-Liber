#if os(iOS) || os(macOS)
// linux-blind: GRDB / ZIPFoundation（平台边界，Linux 空编译单元） —— 改动须经 macOS CI 验证
import Foundation
import GRDB
import ZIPFoundation
import Domain

/// 损坏数据库修复的文件级服务（业主 2026-10-30：损坏库单独接口四动作）。
///
/// 职责边界：**只做「数据库文件 ↔ 压缩包 / 校验 / 替换 / 清除」的机械操作**，
/// 不含任何 UI 文案与启动编排（编排在 App/DatabaseBootModel）。
///
/// 安全纪律：
/// - 校验（header / integrity_check / user_version / 必需表）通过前**绝不改动**患者库；
/// - 替换时原损坏文件（含 WAL/SHM）改名保留为 `.corrupt-<ts>` 副本，失败可回滚；
/// - 清除只针对患者库文件名全集与 `.corrupt-*` 副本，绝不触碰原件目录（BR-002）。
public enum DatabaseRecoveryService {
    /// 压缩包条目（name 为包内路径，path 为磁盘路径）。
    public struct ZipEntry: Sendable, Equatable {
        public let name: String
        public let path: String
        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    public struct RepairReport: Sendable, Equatable {
        public let userVersion: Int
        public init(userVersion: Int) { self.userVersion = userVersion }
    }

    /// 患者库文件的伴生后缀（SQLite WAL 模式）。
    public static let sidecarSuffixes = ["-wal", "-shm", "-journal"]

    /// 损坏库副本前缀（替换时旧文件改名保留；清除时一并删除）。
    public static let corruptMarker = ".corrupt-"

    /// 打包（`.zip`，deflate）到 destination；返回 destination。
    /// 条目名做最小安全校验（拒绝绝对路径/反斜杠/`..`/控制字符）。
    @discardableResult
    public static func makeArchive(entries: [ZipEntry], destination: URL,
                                   fileManager: FileManager = .default) throws -> URL {
        guard !entries.isEmpty else { throw DatabaseRepairError.missingFile }
        let archiveURL = destination
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }
        do {
            let archive = try Archive(url: archiveURL, accessMode: .create)
            for entry in entries {
                guard !entry.name.hasPrefix("/"), !entry.name.contains("\\"),
                      !entry.name.contains(":"),
                      !entry.name.split(separator: "/").contains(".."),
                      !entry.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                else { throw DatabaseRepairError.archiveInvalid("unsafe entry: \(entry.name)") }
                guard fileManager.fileExists(atPath: entry.path) else {
                    // 伴生文件可能不存在（无 WAL 的干净关闭）；主库缺失才致命。
                    if entry.name.hasSuffix(".sqlite") { throw DatabaseRepairError.missingFile }
                    continue
                }
                try archive.addEntry(with: entry.name, fileURL: URL(fileURLWithPath: entry.path),
                                     compressionMethod: .deflate)
            }
        } catch let error as DatabaseRepairError {
            throw error
        } catch {
            throw DatabaseRepairError.ioFailed("打包失败: \(error)")
        }
        return archiveURL
    }

    /// 从压缩包解出唯一的 `.sqlite` 成员到 directory；返回解出路径。
    /// 路径穿越/多候选/无候选一律拒绝（用户修复包不可信）。
    public static func extractRepairedDatabase(from archiveURL: URL, into directory: URL,
                                               fileManager: FileManager = .default) throws -> URL {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read, pathEncoding: nil)
        } catch {
            throw DatabaseRepairError.archiveInvalid("无法打开压缩包")
        }
        var candidates: [Entry] = []
        for entry in archive {
            guard entry.type == .file else { continue }
            let name = entry.path
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !name.split(separator: "/").contains(".."),
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw DatabaseRepairError.archiveInvalid("压缩包包含不安全路径") }
            if name.lowercased().hasSuffix(".sqlite") || name.lowercased().hasSuffix(".db") {
                candidates.append(entry)
            }
        }
        guard candidates.count == 1, let entry = candidates.first else {
            throw DatabaseRepairError.archiveInvalid(
                candidates.isEmpty ? "压缩包内未找到数据库文件" : "压缩包内存在多个数据库文件")
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(
                (entry.path as NSString).lastPathComponent)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            _ = try archive.extract(entry, to: target)
            return target
        } catch {
            throw DatabaseRepairError.ioFailed("解压失败: \(error)")
        }
    }

    /// 校验用户修复后的数据库：SQLite header → 可读 → 版本 → 必需表 → 完整性。
    /// 全部通过才返回；任何一项失败都不改动本机文件（调用方在确认后才替换）。
    public static func validateRepairedDatabase(
        at url: URL,
        supportedVersion: Int = SchemaMigrations.latestVersion,
        requiredTables: [String] = DatabaseBootPolicy.requiredTables,
        fileManager: FileManager = .default) throws -> RepairReport {
        guard fileManager.fileExists(atPath: url.path) else {
            throw DatabaseRepairError.missingFile
        }
        // 1) SQLite magic（16 字节）。先于打开：非 SQLite 文件不得进入 GRDB。
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DatabaseRepairError.unreadable("\(error)")
        }
        defer { try? handle.close() } // try?-ok: 只读句柄关闭失败不影响已验证结果
        let head: Data?
        do {
            head = try handle.read(upToCount: 16)
        } catch {
            throw DatabaseRepairError.unreadable("\(error)")
        }
        guard head == Data("SQLite format 3\u{0}".utf8) else {
            throw DatabaseRepairError.notSQLite
        }

        var config = Configuration()
        config.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw DatabaseRepairError.unreadable("\(error)")
        }
        defer { try? queue.close() } // try?-ok: 只读连接关闭失败由系统回收，不影响校验结论

        let version: Int
        let tables: Set<String>
        let integrity: String?
        do {
            version = try queue.read { db in
                try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            }
            tables = Set(try queue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            })
            integrity = try queue.read { db in
                try String.fetchOne(db, sql: "PRAGMA integrity_check")
            }
        } catch {
            throw DatabaseRepairError.unreadable("\(error)")
        }
        guard version >= 1 else { throw DatabaseRepairError.unsupportedVersion(version) }
        guard version <= supportedVersion else {
            throw DatabaseRepairError.tooNew(found: version, supported: supportedVersion)
        }
        let missing = requiredTables.filter { !tables.contains($0) }
        guard missing.isEmpty else { throw DatabaseRepairError.missingTables(missing) }
        guard integrity?.lowercased() == "ok" else {
            throw DatabaseRepairError.integrityFailed(integrity ?? "unknown")
        }
        return RepairReport(userVersion: version)
    }

    /// 用修复后的文件替换患者库：原文件（含伴生）改名 `.corrupt-<ts>` 保留；
    /// 复制失败回滚改名，绝不留下「既无原文件又无新文件」的半状态。
    public static func install(repairedPath: String, patientPath: String,
                               now: Date = Date(),
                               fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: repairedPath) else {
            throw DatabaseRepairError.missingFile
        }
        let stamp = Int(now.timeIntervalSince1970)
        var archived: [(from: String, to: String)] = []
        do {
            for suffix in [""] + sidecarSuffixes {
                let source = patientPath + suffix
                guard fileManager.fileExists(atPath: source) else { continue }
                let target = patientPath + corruptMarker + "\(stamp)" + suffix
                if fileManager.fileExists(atPath: target) {
                    try fileManager.removeItem(atPath: target)
                }
                try fileManager.moveItem(atPath: source, toPath: target)
                archived.append((source, target))
            }
            // 修复文件复制为新主库；不携带任何伴生文件（新库自带自己的状态）。
            if fileManager.fileExists(atPath: patientPath) {
                try fileManager.removeItem(atPath: patientPath)
            }
            try fileManager.copyItem(atPath: repairedPath, toPath: patientPath)
        } catch {
            // 回滚：删掉可能的半复制新库，把改名副本搬回原路径。
            if fileManager.fileExists(atPath: patientPath),
               !archived.contains(where: { $0.from == patientPath }) {
                try? fileManager.removeItem(atPath: patientPath) // try?-ok: 回滚清理半复制文件，失败不影响回滚语义
            }
            for pair in archived.reversed() {
                if fileManager.fileExists(atPath: pair.to),
                   !fileManager.fileExists(atPath: pair.from) {
                    try? fileManager.moveItem(atPath: pair.to, toPath: pair.from) // try?-ok: 回滚尽力搬回；失败由错误上报承担
                }
            }
            throw DatabaseRepairError.ioFailed("替换失败: \(error)")
        }
    }

    /// 删除患者库文件名全集（规范名 + 历史名 + 伴生 + `.corrupt-*` 副本）。
    /// 只在本目录操作；原件目录不动（BR-002）。
    public static func erasePatientDatabase(patientPath: String,
                                            fileManager: FileManager = .default) throws {
        let dir = URL(fileURLWithPath: patientPath).deletingLastPathComponent()
        let baseName = URL(fileURLWithPath: patientPath).lastPathComponent
        var names = Set(PatientDatabaseNames.all)
        names.insert(baseName)
        do {
            for name in names {
                for suffix in [""] + sidecarSuffixes {
                    let path = dir.appendingPathComponent(name + suffix).path
                    if fileManager.fileExists(atPath: path) {
                        try fileManager.removeItem(atPath: path)
                    }
                }
            }
            // `.corrupt-*` 副本（任意注册名 + 时间戳 + 伴生后缀）。
            let entries: [String]
            do {
                entries = try fileManager.contentsOfDirectory(atPath: dir.path)
            } catch {
                entries = []
            }
            for entry in entries where entry.contains(corruptMarker) {
                let isPatientCopy = names.contains { entry.hasPrefix($0 + corruptMarker) }
                if isPatientCopy {
                    try fileManager.removeItem(atPath: dir.appendingPathComponent(entry).path)
                }
            }
        } catch {
            throw DatabaseRepairError.ioFailed("删除失败: \(error)")
        }
    }
}

public enum DatabaseRepairError: Error, Equatable, Sendable {
    case missingFile
    case notSQLite
    case unreadable(String)
    case integrityFailed(String)
    case tooNew(found: Int, supported: Int)
    case unsupportedVersion(Int)
    case missingTables([String])
    case archiveInvalid(String)
    case ioFailed(String)
}
#endif
