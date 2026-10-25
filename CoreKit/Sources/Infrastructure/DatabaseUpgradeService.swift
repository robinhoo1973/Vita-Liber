#if os(iOS) || os(macOS)
// linux-blind: GRDB only links on Apple platforms; Linux compiles an empty unit.
import Foundation
import GRDB
import Domain

/// 患者库升级的唯一包装层：源版本校验 → `GRDBStore`（唯一迁移引擎）→ 目标版本复核。
///
/// 本层不实现任何 ALTER/DDL；它只把“传进来的源/目标版本”变成可执行断言，
/// 防止迁移调用方与物理库版本脱节（历史库、UI 状态都不是事实源）。
public enum DatabaseUpgradeError: Error, Equatable {
    case sourceMismatch(expected: Int, found: Int?)
    case targetMismatch(expected: Int, found: Int?)
    case missingRequiredTables
}

public enum DatabaseUpgradeService {
    /// - Parameters:
    ///   - source: 已探测到的源版本；`nil` = 全新库（由调用方先证明无原件证据）。
    ///   - target: 代码内 `SchemaMigrations.latestVersion`。
    public static func open(at path: String,
                            from source: Int?,
                            to target: Int,
                            requiredTables: [String]) throws -> GRDBStore {
        if let source {
            let before = DatabaseProbe.inspect(
                path: path, requiredTables: requiredTables, originalsPresent: false)
            guard before.exists, before.headerValid, before.observedVersion == source else {
                throw DatabaseUpgradeError.sourceMismatch(expected: source, found: before.observedVersion)
            }
        }
        let store = try GRDBStore.pool(at: path)
        let after = DatabaseProbe.inspect(
            path: path, requiredTables: requiredTables, originalsPresent: false)
        guard after.observedVersion == target else {
            throw DatabaseUpgradeError.targetMismatch(expected: target, found: after.observedVersion)
        }
        guard after.hasAllRequiredTables else {
            throw DatabaseUpgradeError.missingRequiredTables
        }
        return store
    }
}
#endif
