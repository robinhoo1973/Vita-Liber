#if os(iOS) || os(macOS)
// linux-blind: GRDB only links on Apple platforms; Linux compiles an empty unit.
import Foundation
import GRDB
import Domain

/// 迁移前安全快照（2026-11-01 迁移安全网；三席两轮裁决 B1）。
///
/// 为什么用 GRDB 的 SQLite backup API（`DatabaseReader.backup(to:pagesPerStep:progress:)`）：
/// - WAL 下给出一致快照，不依赖「启动期无写者」这一无法强制的假设；
/// - 官方在线备份路径，比自写 `wal_checkpoint + copy` / `VACUUM INTO` 更稳
///   （后者非崩溃原子且依赖目标不存在）；
/// - 目标写临时文件 → fsync → rename，崩溃只留 `.partial-*`，下次启动清理。
///
/// 安全纪律：
/// - 只服务 `.migrate` 路径；`ready/fresh/tooNew/corrupt` 不建快照；
/// - 快照含 PHI：`Application Support/VitaLiber/boot/checkpoints`、排除备份、
///   `.completeUnlessOpen`、每库至多一份；
/// - 迁移成功且容器发布后由 App 删除；失败保留供「恢复迁移前状态」；
/// - 快照失败 fail-closed（库未动），不回退到一致性假设不同的文件复制。
public struct MigrationCheckpoint: Sendable, Equatable {
    public let path: String
    public let databaseName: String
    public let sourceVersion: Int
    public let targetVersion: Int
    public let sizeBytes: Int64
    public let createdAt: Date

    public init(path: String, databaseName: String, sourceVersion: Int,
                targetVersion: Int, sizeBytes: Int64, createdAt: Date) {
        self.path = path
        self.databaseName = databaseName
        self.sourceVersion = sourceVersion
        self.targetVersion = targetVersion
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
    }

    public var fileURL: URL { URL(fileURLWithPath: path) }
}

public enum MigrationCheckpointError: Error, Equatable, Sendable {
    case databaseMissing
    case sourceVersionMismatch(expected: Int, found: Int?)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case checkpointFailed(String)
    case restoreValidationFailed(String)
}

public enum MigrationCheckpointStore {
    /// 与启动收据同根、不同子目录；L0[21] 存储边界只允许 Application Support。
    public static let directoryName = "VitaLiber/boot/checkpoints"
    public static let fileMarker = ".pre-migration-"
    public static let partialMarker = ".partial-"
    /// 备份与迁移表重建的最坏并行空间：快照 1× + 新表/临时 1× + 20MB 余量。
    public static let diskHeadroomBytes: Int64 = 20 * 1024 * 1024

    public static func directory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// 迁移前准备快照；同 `from/to` 的有效快照复用（上次崩溃留下的才是
    /// 干净回滚点），半成品/异版本旧快照先清理。
    public static func prepare(databasePath: String, from: Int, to: Int,
                               fileManager: FileManager = .default) throws -> MigrationCheckpoint {
        guard fileManager.fileExists(atPath: databasePath) else {
            throw MigrationCheckpointError.databaseMissing
        }
        let directory = directory(fileManager: fileManager)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MigrationCheckpointError.checkpointFailed("create directory: \(error)")
        }
        let databaseName = URL(fileURLWithPath: databasePath).lastPathComponent
        let finalURL = finalURL(databaseName: databaseName, from: from, to: to,
                                directory: directory)
        if fileManager.fileExists(atPath: finalURL.path) {
            if let existing = checkpoint(at: finalURL, source: from, target: to,
                                         fileManager: fileManager) {
                return existing
            }
            try? fileManager.removeItem(at: finalURL) // try?-ok: 无效旧快照不得阻断新快照
        }
        cleanupPartials(databaseName: databaseName, directory: directory,
                        fileManager: fileManager)

        let attributes = try? fileManager.attributesOfItem(atPath: databasePath) // try?-ok: 属性不可读按 0 处理
        let sourceSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let needed = sourceSize <= 0 ? 0 : sourceSize * 2 + diskHeadroomBytes
        try requireDiskSpace(needed: needed, at: databasePath, fileManager: fileManager)

        let partialURL = directory.appendingPathComponent(
            finalURL.lastPathComponent + partialMarker + UUID().uuidString)
        do {
            var configuration = Configuration()
            configuration.busyMode = .timeout(2)
            configuration.foreignKeysEnabled = false
            let source = try DatabaseQueue(path: databasePath, configuration: configuration)
            defer { try? source.close() } // try?-ok: 备份完成后关闭源连接
            let sourceVersion = try source.read { db in
                try Int.fetchOne(db, sql: "PRAGMA user_version")
            }
            guard sourceVersion == from else {
                throw MigrationCheckpointError.sourceVersionMismatch(
                    expected: from, found: sourceVersion)
            }
            let destination = try DatabaseQueue(path: partialURL.path,
                                                configuration: configuration)
            do {
                try source.backup(to: destination, pagesPerStep: 256)
                try? destination.close() // try?-ok: 关闭失败由进程回收
            } catch {
                try? destination.close() // try?-ok: 失败路径尽力关闭
                throw error
            }
            synchronizeFile(at: partialURL.path)
            try fileManager.moveItem(at: partialURL, to: finalURL)
            applyPrivacyAttributes(at: finalURL, fileManager: fileManager)
        } catch let checkpointError as MigrationCheckpointError {
            try? fileManager.removeItem(at: partialURL) // try?-ok: 失败路径清理半成品
            throw checkpointError
        } catch {
            try? fileManager.removeItem(at: partialURL) // try?-ok: 失败路径清理半成品
            throw MigrationCheckpointError.checkpointFailed(String(describing: error))
        }
        guard let checkpoint = checkpoint(at: finalURL, source: from, target: to,
                                          fileManager: fileManager) else {
            try? fileManager.removeItem(at: finalURL) // try?-ok: 校验失败删除无效快照
            throw MigrationCheckpointError.checkpointFailed("checkpoint failed validation")
        }
        return checkpoint
    }

    /// `.ready` 启动时查找「目标版本等于当前库版本」的遗留快照（上次迁移成功但
    /// 容器发布前被杀）。返回 nil 表示无遗留；调用方决定补跑 quick_check 后删除。
    public static func leftover(databasePath: String, currentVersion: Int,
                                fileManager: FileManager = .default) -> MigrationCheckpoint? {
        let directory = directory(fileManager: fileManager)
        let databaseName = URL(fileURLWithPath: databasePath).lastPathComponent
        let prefix = databaseName + fileMarker
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] // try?-ok: 目录不可读=无遗留
        for entry in entries.sorted() {
            guard entry.hasPrefix(prefix), entry.hasSuffix(".sqlite") else { continue }
            let middle = entry.dropFirst(prefix.count).dropLast(".sqlite".count)
            guard let range = middle.range(of: "-to-v") else { continue }
            let fromText = middle[..<range.lowerBound].dropFirst() // 去掉前缀 "v"
            let toText = middle[range.upperBound...].dropFirst() // 去掉前缀 "v"
            guard let from = Int(fromText), let to = Int(toText) else { continue }
            let url = directory.appendingPathComponent(entry)
            if to == currentVersion,
               let checkpoint = checkpoint(at: url, source: from, target: to,
                                           fileManager: fileManager) {
                return checkpoint
            }
        }
        return nil
    }

    /// 删除该库全部快照与半成品（成功启动/删除重建/恢复旧备份后调用）。
    public static func discardAll(databasePath: String,
                                  fileManager: FileManager = .default) {
        let directory = directory(fileManager: fileManager)
        let databaseName = URL(fileURLWithPath: databasePath).lastPathComponent
        let prefix = databaseName + fileMarker
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] // try?-ok: 清理尽力而为
        for entry in entries where entry.hasPrefix(prefix) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(entry)) // try?-ok: 清理尽力而为
        }
    }

    /// 校验并恢复快照：先 integrity/必需表/版本校验，再原子替换当前库；
    /// 当前库（半升级/损坏）由 `DatabaseRecoveryService.install` 归档为 `.corrupt-*`。
    /// **不删除快照**——恢复后再次迁移失败仍有回滚点；成功启动后统一清理。
    public static func restore(_ checkpoint: MigrationCheckpoint, patientPath: String,
                               fileManager: FileManager = .default) throws {
        let report: DatabaseRecoveryService.RepairReport
        do {
            report = try DatabaseRecoveryService.validateRepairedDatabase(
                at: checkpoint.fileURL)
        } catch {
            throw MigrationCheckpointError.restoreValidationFailed(String(describing: error))
        }
        guard report.userVersion == checkpoint.sourceVersion else {
            throw MigrationCheckpointError.restoreValidationFailed(
                "version \(report.userVersion) != source \(checkpoint.sourceVersion)")
        }
        do {
            try DatabaseRecoveryService.install(repairedPath: checkpoint.path,
                                                patientPath: patientPath,
                                                fileManager: fileManager)
        } catch {
            throw MigrationCheckpointError.restoreValidationFailed(String(describing: error))
        }
    }

    // MARK: - 内部

    private static func finalURL(databaseName: String, from: Int, to: Int,
                                 directory: URL) -> URL {
        directory.appendingPathComponent(
            databaseName + fileMarker + "v\(from)-to-v\(to).sqlite")
    }

    private static func checkpoint(at url: URL, source: Int, target: Int,
                                   fileManager: FileManager) -> MigrationCheckpoint? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path) // try?-ok: 属性不可读=无效快照
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return nil }
        let probe = DatabaseProbe.inspect(path: url.path, requiredTables: [],
                                          originalsPresent: false, fileManager: fileManager)
        guard probe.exists, probe.headerValid, probe.observedVersion == source else {
            return nil
        }
        let created = (attributes?[.creationDate] as? Date) ?? Date()
        return MigrationCheckpoint(
            path: url.path,
            databaseName: URL(fileURLWithPath: url.path).lastPathComponent
                .components(separatedBy: fileMarker).first ?? "",
            sourceVersion: source,
            targetVersion: target,
            sizeBytes: size,
            createdAt: created)
    }

    private static func cleanupPartials(databaseName: String, directory: URL,
                                        fileManager: FileManager) {
        let prefix = databaseName + fileMarker
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] // try?-ok: 清理尽力而为
        for entry in entries where entry.hasPrefix(prefix) && entry.contains(partialMarker) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(entry)) // try?-ok: 清理尽力而为
        }
    }

    private static func requireDiskSpace(needed: Int64, at databasePath: String,
                                         fileManager: FileManager) throws {
        guard needed > 0 else { return }
        let directory = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
        guard let values = try? directory.resourceValues( // try?-ok: 容量不可用则放行（不阻断启动）
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return }
        if available < needed {
            throw MigrationCheckpointError.insufficientDiskSpace(
                needed: needed, available: available)
        }
    }

    private static func synchronizeFile(at path: String) {
        guard let handle = FileHandle(forUpdatingAtPath: path) else { return }
        defer { try? handle.close() } // try?-ok: 关闭失败不影响已写入数据
        try? handle.synchronizeFile() // try?-ok: fsync 尽力而为；失败由下次校验暴露
    }

    private static func applyPrivacyAttributes(at url: URL, fileManager: FileManager) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values) // try?-ok: 备份排除尽力而为
        #if os(iOS)
        try? fileManager.setAttributes( // try?-ok: 保护类设置失败不改变可用性
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path)
        #endif
    }
}
#endif
