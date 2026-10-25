#if os(iOS) || os(macOS)
// linux-blind: GRDB only links on Apple platforms; Linux compiles an empty unit.
import Foundation
import GRDB
import Domain

/// 只读探测物理数据库文件。绝不使用 `SQLITE_OPEN_CREATE`：
/// 文件缺失时必须让上层决定“新建 / 原件证据阻断”，不能让 SQLite 静默建空库。
public enum DatabaseProbe {
    public static func inspect(path: String,
                               requiredTables: [String],
                               originalsPresent: Bool,
                               fileManager: FileManager = .default) -> DatabaseProbeSnapshot {
        guard fileManager.fileExists(atPath: path) else {
            return DatabaseProbeSnapshot(
                exists: false, sizeBytes: 0, headerValid: false, observedVersion: nil,
                tableCount: 0, requiredTablesPresent: 0,
                requiredTablesExpected: requiredTables.count, originalsPresent: originalsPresent)
        }
        let attributes = try? fileManager.attributesOfItem(atPath: path) // try?-ok: 属性不可读按 0 字节处理，交由策略 fail-closed
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let headerValid = hasSQLiteHeader(path)
        guard size > 0, headerValid else {
            return DatabaseProbeSnapshot(
                exists: true, sizeBytes: size, headerValid: headerValid, observedVersion: nil,
                tableCount: 0, requiredTablesPresent: 0,
                requiredTablesExpected: requiredTables.count, originalsPresent: originalsPresent)
        }

        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = false
        configuration.busyMode = .timeout(1)
        do {
            let queue = try DatabaseQueue(path: path, configuration: configuration)
            let (version, tables) = try queue.read { db -> (Int?, [String]) in
                let version = try Int.fetchOne(db, sql: "PRAGMA user_version")
                let tables = try String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
                return (version, tables)
            }
            let present = Set(tables).intersection(requiredTables).count
            return DatabaseProbeSnapshot(
                exists: true, sizeBytes: size, headerValid: true, observedVersion: version,
                tableCount: tables.count, requiredTablesPresent: present,
                requiredTablesExpected: requiredTables.count, originalsPresent: originalsPresent)
        } catch {
            return DatabaseProbeSnapshot(
                exists: true, sizeBytes: size, headerValid: true, observedVersion: nil,
                tableCount: 0, requiredTablesPresent: 0,
                requiredTablesExpected: requiredTables.count, originalsPresent: originalsPresent)
        }
    }

    private static func hasSQLiteHeader(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() } // try?-ok: 只读句柄关闭失败不影响探测结果
        let header = (try? handle.read(upToCount: 16)) ?? nil // try?-ok: 读失败=无有效头
        return header == Data("SQLite format 3\0".utf8)
    }
}
#endif
