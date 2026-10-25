#if os(iOS) || os(macOS)
// linux-blind: GRDB only links on Apple platforms; Linux compiles an empty unit.
import Foundation
import GRDB

/// 医疗目录的 **App catalog schema** 探测。
///
/// 只认 SQLite `catalog_meta.app_catalog_schema_version`（v4=`"4"`，v5=`"5"`）。
/// **不**回落 `PRAGMA user_version` / `catalog_meta.schema_version`——那是内容
/// schema（v4 为 7），混用会把 v5 误判成 v4。缺键/非整数/未知值一律 fail-closed。
public enum CatalogSchemaProbe {
    public enum State: Sendable, Equatable {
        case missing
        case unreadable
        /// 文件存在但契约键缺失/非整数/未知版本；关联值为可解析出的版本号。
        case unsupported(Int?)
        case v4
        case v5

        public var version: Int? {
            switch self {
            case .v4: return 4
            case .v5: return 5
            case .unsupported(let version): return version
            case .missing, .unreadable: return nil
            }
        }
    }

    public static func inspect(path: String, fileManager: FileManager = .default) -> State {
        guard fileManager.fileExists(atPath: path) else { return .missing }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = false
        configuration.busyMode = .timeout(1)
        do {
            let queue = try DatabaseQueue(path: path, configuration: configuration)
            return try queue.read { db in
                let hasTable = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(
                      SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'catalog_meta')
                    """) ?? false
                guard hasTable else { return .unsupported(nil) }
                let raw = try String.fetchOne(
                    db, sql: "SELECT value FROM catalog_meta WHERE key = 'app_catalog_schema_version'")
                guard let raw, let version = Int(raw) else { return .unsupported(nil) }
                switch version {
                case 4: return .v4
                case 5: return .v5
                default: return .unsupported(version)
                }
            }
        } catch {
            return .unreadable
        }
    }
}
#endif
