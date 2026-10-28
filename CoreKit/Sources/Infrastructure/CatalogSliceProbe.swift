#if os(iOS) || os(macOS)
// linux-blind: GRDB only links on Apple platforms; Linux compiles an empty unit.
import Foundation
import GRDB

/// 切片安装/启动探测：表集精确 == manifest 数据表 ∪ {`slice_meta`}（禁
/// `catalog_meta`/FTS/多余表）+ slice_meta 契约（`CatalogSliceMetaContract`）+
/// `integrity_check`/`foreign_key_check` + 可选 COUNT(*) 对账（安装期一次）。
///
/// 只认切片契约，绝不回落 v4 的 `catalog_meta.app_catalog_schema_version` /
/// `PRAGMA user_version` 语义——切片没有这些键，回落即误判。
public enum CatalogSliceProbe {
    public enum State: Sendable, Equatable {
        case missing
        case unreadable
        case contractViolation(CatalogSliceMetaContract.Violation)
        case tableSetMismatch
        case integrityFailed
        case countsMismatch
        case ready(CatalogSliceMetaContract.Observed)
    }

    /// `expectedTables`/`expectedCounts` 来自已验签 manifest（`CatalogSliceManifestDecoder`）；
    /// `verifyCounts` 只在安装期 true（7 表全扫 <200ms），启动探测只做元数据级。
    public static func inspect(path: String, kind: CatalogSliceKind,
                               expectedTables: Set<String>, expectedCounts: [String: Int64],
                               verifyCounts: Bool, fileManager: FileManager = .default) -> State {
        guard fileManager.fileExists(atPath: path) else { return .missing }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = false
        configuration.busyMode = .timeout(1)
        do {
            let queue = try DatabaseQueue(path: path, configuration: configuration)
            return try queue.read { db in
                let tables = Set(try String.fetchAll(db, sql: """
                    SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                    """))
                guard tables == expectedTables.union(["slice_meta"]) else { return .tableSetMismatch }
                let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM slice_meta")
                    .map { (key: $0["key"] as String, value: $0["value"] as String) }
                let observed: CatalogSliceMetaContract.Observed
                do {
                    observed = try CatalogSliceMetaContract.validate(
                        rows: rows, expectedTables: expectedTables, expectedCounts: expectedCounts)
                } catch let violation as CatalogSliceMetaContract.Violation {
                    return .contractViolation(violation)
                }
                guard try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"],
                      try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil else {
                    return .integrityFailed
                }
                if verifyCounts {
                    for table in expectedTables.sorted() {
                        let actual = try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? -1
                        guard actual == expectedCounts[table] else { return .countsMismatch }
                    }
                }
                return .ready(observed)
            }
        } catch {
            return .unreadable
        }
    }
}
#endif
