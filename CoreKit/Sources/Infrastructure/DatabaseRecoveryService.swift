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

    /// 解包硬上限（用户修复包不可信；防 zip bomb / 磁盘打满）。
    public static let maxArchiveEntries = 16
    public static let maxArchiveUncompressedBytes: Int64 = 2 << 30
    /// 临时替换文件后缀（copy 完成后同卷 rename 原子落位）。
    public static let incomingMarker = ".incoming-"

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
        // 成员选择：优先唯一「注册名主库」（PatientDatabaseNames.all）——App 自身
        // 导出的包含主库+伴生+历史库，历史库不得造成「多库拒绝」的自闭闭环；
        // 无注册名候选时接受唯一 .sqlite/.db（第三方修复产物）。多个主库/多个
        // 未知库一律拒绝。伴生（-wal/-shm）不参与选择也不提取。
        let canonicalNames = Set(PatientDatabaseNames.all.map { $0.lowercased() })
        var canonical: [Entry] = []
        var others: [Entry] = []
        var count = 0
        var total: Int64 = 0
        for entry in archive {
            count += 1
            guard count <= maxArchiveEntries else {
                throw DatabaseRepairError.archiveInvalid("压缩包条目过多")
            }
            if entry.type == .symlink {
                throw DatabaseRepairError.archiveInvalid("压缩包包含符号链接")
            }
            guard entry.type == .file else { continue }
            let name = entry.path
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !name.split(separator: "/").contains(".."),
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw DatabaseRepairError.archiveInvalid("压缩包包含不安全路径") }
            let size = Int64(entry.uncompressedSize)
            guard size >= 0, size <= maxArchiveUncompressedBytes,
                  total <= maxArchiveUncompressedBytes - size else {
                throw DatabaseRepairError.archiveInvalid("压缩包展开量超限")
            }
            total += size
            let base = (name as NSString).lastPathComponent.lowercased()
            if base.hasSuffix("-wal") || base.hasSuffix("-shm") || base.hasSuffix("-journal") {
                // 静默忽略 WAL = 静默丢已提交事务；自包含修复库必须先在外部 checkpoint。
                throw DatabaseRepairError.archiveHasSidecars
            }
            guard base.hasSuffix(".sqlite") || base.hasSuffix(".db") else { continue }
            if canonicalNames.contains(base) {
                canonical.append(entry)
            } else {
                others.append(entry)
            }
        }
        let chosen: Entry
        if canonical.count == 1 {
            chosen = canonical[0]
        } else if canonical.isEmpty, others.count == 1 {
            chosen = others[0]
        } else if canonical.count > 1 || others.count > 1 {
            throw DatabaseRepairError.archiveMultiple
        } else {
            throw DatabaseRepairError.archiveInvalid("压缩包内未找到数据库文件")
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(
                (chosen.path as NSString).lastPathComponent)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            _ = try archive.extract(chosen, to: target)
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
        let incoming = patientPath + incomingMarker + UUID().uuidString
        var archived: [(from: String, to: String)] = []
        do {
            // 0) 磁盘余量预检（新库 + 20 MB 余量）；不足直接拒绝，不进入改名阶段。
            try Self.requireDiskSpace(for: repairedPath, at: patientPath, fileManager: fileManager)
            // 1) 新库先完整复制到同目录 incoming（原库完全不动——复制失败无副作用）。
            try fileManager.copyItem(atPath: repairedPath, toPath: incoming)
            try Self.synchronizeFile(at: incoming)
            // 2) 伴生先归档、主库最后（崩溃窗口里主库缺失可由修复入口兜底；
            //    副本名带 UUID，防同秒二次替换误删上一份）。
            for suffix in sidecarSuffixes + [""] {
                let source = patientPath + suffix
                guard fileManager.fileExists(atPath: source) else { continue }
                var target = patientPath + corruptMarker + "\(stamp)" + suffix
                if fileManager.fileExists(atPath: target) {
                    target = patientPath + corruptMarker + "\(stamp)-" + UUID().uuidString + suffix
                }
                try fileManager.moveItem(atPath: source, toPath: target)
                archived.append((source, target))
                Self.excludeFromBackup(path: target)
            }
            // 3) 同卷 rename 原子落位（incoming → 患者库路径）。
            try fileManager.moveItem(atPath: incoming, toPath: patientPath)
            try Self.synchronizeFile(at: patientPath)
        } catch {
            // 回滚：仅当主库确已归档（患者路径上是新库/半成品）才清患者路径；
            // 主库尚未归档时它仍是唯一原件，绝不能删（四席复审修正）。
            let mainArchived = archived.contains { $0.from == patientPath }
            if mainArchived, fileManager.fileExists(atPath: patientPath) {
                try? fileManager.removeItem(atPath: patientPath) // try?-ok: 回滚清理新库/半成品，失败仍继续搬回归档
            }
            if fileManager.fileExists(atPath: incoming) {
                try? fileManager.removeItem(atPath: incoming) // try?-ok: 回滚清理未落位副本
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

    /// 建一个 baseline 空库（用 App 自身迁移链，避免绕过启动门手工造库）。
    /// 仅供用户显式确认后的「删除重建 / staged 备份恢复」调用；调用后立即关闭池，
    /// 避免 install/rename 时仍有打开的连接。
    public static func createBaselineDatabase(at path: String) throws {
        let store = try GRDBStore.stage(at: path)
        try store.writer.close()
    }

    /// 尽力 fsync 文件内容（同目录 rename 原子，但断电持久性需同步；目录级
    /// fsync 仍需更底层 API，登记崩溃一致性债）。
    private static func synchronizeFile(at path: String) {
        guard let handle = FileHandle(forUpdatingAtPath: path) else { return }
        defer { try? handle.close() } // try?-ok: 同步句柄关闭失败不影响已写入数据
        try? handle.synchronizeFile() // try?-ok: fsync 尽力而为；失败不改变替换语义
    }

    /// 磁盘余量预检（新库大小 + 20 MB）。容量字段不可用时放行（不阻断修复）。
    private static func requireDiskSpace(for sourcePath: String, at patientPath: String,
                                         fileManager: FileManager) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: sourcePath) // try?-ok: 容量预检尽力而为，属性不可读则放行
        let sourceSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard sourceSize > 0 else { return }
        let url = URL(fileURLWithPath: patientPath).deletingLastPathComponent()
        let values = try? url.resourceValues( // try?-ok: 容量字段不可用则放行，不阻断修复
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let capacity = values?.volumeAvailableCapacityForImportantUsage
        guard let capacity else { return }
        let needed = sourceSize + 20 * 1024 * 1024
        if capacity < needed {
            throw DatabaseRepairError.ioFailed("磁盘空间不足")
        }
    }

    /// 归档副本不进入 iCloud/设备备份（PHI 全库副本，隐私最小化）。
    private static func excludeFromBackup(path: String) {
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values) // try?-ok: 备份排除尽力而为，不影响替换结果
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
            // 伴生先删、主库最后（崩溃窗口里主库仍在 → 启动门不会判 fresh）。
            for name in names {
                for suffix in sidecarSuffixes + [""] {
                    let path = dir.appendingPathComponent(name + suffix).path
                    if fileManager.fileExists(atPath: path) {
                        try fileManager.removeItem(atPath: path)
                    }
                }
            }
            // `.corrupt-*`/`.incoming-*` 副本（任意注册名 + 后缀）。
            let entries = try fileManager.contentsOfDirectory(atPath: dir.path)
            for entry in entries where entry.contains(corruptMarker) || entry.contains(incomingMarker) {
                let isPatientCopy = names.contains {
                    entry.hasPrefix($0 + corruptMarker) || entry.hasPrefix($0 + incomingMarker)
                }
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
    /// 压缩包内存在多个数据库候选（多个注册名主库或多个未知库）——拒绝猜测。
    case archiveMultiple
    /// 压缩包含 SQLite 伴生（-wal/-shm/-journal）——拒绝静默丢 WAL。
    case archiveHasSidecars
    case ioFailed(String)
}
#endif
