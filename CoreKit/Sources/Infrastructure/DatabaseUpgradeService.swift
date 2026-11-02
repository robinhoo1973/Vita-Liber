#if os(iOS) || os(macOS)
// linux-blind: GRDB only links on Apple platforms; Linux compiles an empty unit.
import Foundation
import GRDB
import Domain

/// 患者库升级的唯一包装层：源版本校验 → `GRDBStore`（唯一迁移引擎）→ 目标版本复核
/// → 迁移后结构校验（2026-11-01 安全网）。
///
/// 本层不实现任何 ALTER/DDL；它只把“传进来的源/目标版本”变成可执行断言，
/// 防止迁移调用方与物理库版本脱节（历史库、UI 状态都不是事实源）。
public enum DatabaseUpgradeError: Error, Equatable {
    case sourceMismatch(expected: Int, found: Int?)
    case targetMismatch(expected: Int, found: Int?)
    case missingRequiredTables
    /// 迁移后 `PRAGMA quick_check` 未通过（保留迁移前快照供恢复）。
    case postCheckFailed(String)
}

public enum DatabaseUpgradeService {
    /// - Parameters:
    ///   - source: 已探测到的源版本；`nil` = 全新库（由调用方先证明无原件证据）。
    ///   - target: 代码内 `SchemaMigrations.latestVersion`。
    ///   - migrationProgress: 逐 step 进度；运行在数据库写线程，必须非阻塞投递。
    public static func open(at path: String,
                            from source: Int?,
                            to target: Int,
                            requiredTables: [String],
                            migrationProgress: MigrationProgressHandler? = nil) throws -> GRDBStore {
        if let source {
            let before = DatabaseProbe.inspect(
                path: path, requiredTables: requiredTables, originalsPresent: false)
            guard before.exists, before.headerValid, before.observedVersion == source else {
                throw DatabaseUpgradeError.sourceMismatch(expected: source, found: before.observedVersion)
            }
        }
        let store = try GRDBStore.pool(at: path, migrationProgress: migrationProgress)
        let after = DatabaseProbe.inspect(
            path: path, requiredTables: requiredTables, originalsPresent: false)
        guard after.observedVersion == target else {
            throw DatabaseUpgradeError.targetMismatch(expected: target, found: after.observedVersion)
        }
        guard after.hasAllRequiredTables else {
            throw DatabaseUpgradeError.missingRequiredTables
        }
        // 只在真实迁移路径跑（ready 每次启动跑会把大库启动时延翻倍）。
        // 全库 `quick_check` 只验 B-tree 结构，不验外键——v13 有意保留历史孤儿行，
        // 全局 `foreign_key_check` 会误杀合法旧数据（三席二轮硬约束）。
        if let source, source < target {
            let results: [String]
            do {
                results = try store.writer.read { db in
                    try String.fetchAll(db, sql: "PRAGMA quick_check")
                }
            } catch {
                throw DatabaseUpgradeError.postCheckFailed(String(describing: error))
            }
            guard !results.isEmpty,
                  results.allSatisfy({ $0.caseInsensitiveCompare("ok") == .orderedSame })
            else {
                throw DatabaseUpgradeError.postCheckFailed(results.joined(separator: "; "))
            }
        }
        return store
    }
}
#endif
