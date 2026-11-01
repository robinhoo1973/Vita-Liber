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
            return snapshot(try readState(queue), size: size,
                            requiredTables: requiredTables, originalsPresent: originalsPresent)
        } catch {
            // 只读打开可能因热 journal/WAL 恢复而失败；生产写入会正常恢复，
            // 故此处退回读写连接再探一次（文件已存在，不会静默建库）。
            // 读写回落前再确认文件仍在：探查与回落之间被外部删除时，
            // 非 readonly 打开会以 SQLITE_OPEN_CREATE 建空库（2026-10-27 审查 P3）。
            guard fileManager.fileExists(atPath: path) else {
                return DatabaseProbeSnapshot(
                    exists: false, sizeBytes: 0, headerValid: false, observedVersion: nil,
                    tableCount: 0, requiredTablesPresent: 0,
                    requiredTablesExpected: requiredTables.count, originalsPresent: originalsPresent)
            }
            var writable = Configuration()
            writable.foreignKeysEnabled = false
            writable.busyMode = .timeout(1)
            do {
                let queue = try DatabaseQueue(path: path, configuration: writable)
                return snapshot(try readState(queue), size: size,
                                requiredTables: requiredTables, originalsPresent: originalsPresent)
            } catch {
                return DatabaseProbeSnapshot(
                    exists: true, sizeBytes: size, headerValid: true, observedVersion: nil,
                    tableCount: 0, requiredTablesPresent: 0,
                    requiredTablesExpected: requiredTables.count, originalsPresent: originalsPresent)
            }
        }
    }

    /// 迁移后/遗留快照收尾用的结构校验。返回 `"ok"` 或错误摘要；`nil` =
    /// 文件不可读（调用方按「无法证明损坏」处理，不删除快照）。
    public static func quickCheck(path: String,
                                  fileManager: FileManager = .default) -> String? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        var readonly = Configuration()
        readonly.readonly = true
        readonly.foreignKeysEnabled = false
        readonly.busyMode = .timeout(1)
        if let result = runQuickCheck(path: path, configuration: readonly) {
            return result
        }
        // 热 WAL 只读打开失败时退回读写连接再试一次；文件已存在，不会静默建库。
        guard fileManager.fileExists(atPath: path) else { return nil }
        var writable = Configuration()
        writable.foreignKeysEnabled = false
        writable.busyMode = .timeout(1)
        return runQuickCheck(path: path, configuration: writable)
    }

    private static func runQuickCheck(path: String, configuration: Configuration) -> String? {
        guard let queue = try? DatabaseQueue(path: path, configuration: configuration) else { // try?-ok: 打不开=不判定损坏，调用方保留快照
            return nil
        }
        defer { try? queue.close() } // try?-ok: 校验连接关闭失败由系统回收
        guard let rows = try? queue.read({ db in // try?-ok: 读取失败=不判定损坏
            try String.fetchAll(db, sql: "PRAGMA quick_check")
        }) else { return nil }
        return rows.isEmpty ? "quick_check returned no rows" : rows.joined(separator: "; ")
    }

    private static func readState(_ queue: DatabaseQueue) throws -> (Int?, [String]) {
        try queue.read { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version")
            let tables = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            return (version, tables)
        }
    }

    private static func snapshot(_ state: (Int?, [String]), size: Int64,
                                 requiredTables: [String],
                                 originalsPresent: Bool) -> DatabaseProbeSnapshot {
        let present = Set(state.1).intersection(requiredTables).count
        return DatabaseProbeSnapshot(
            exists: true, sizeBytes: size, headerValid: true, observedVersion: state.0,
            tableCount: state.1.count, requiredTablesPresent: present,
            requiredTablesExpected: requiredTables.count, originalsPresent: originalsPresent)
    }

    private static func hasSQLiteHeader(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() } // try?-ok: 只读句柄关闭失败不影响探测结果
        let header = (try? handle.read(upToCount: 16)) ?? nil // try?-ok: 读失败=无有效头
        return header == Data("SQLite format 3\0".utf8)
    }
}
#endif
