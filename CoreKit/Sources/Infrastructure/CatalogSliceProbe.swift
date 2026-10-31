#if os(iOS) || os(macOS)
// linux-blind: GRDB only links on Apple platforms; Linux compiles an empty unit.
import Domain
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

    /// 启动期自洽探测（boot 判据用；无需 manifest）：期望表集来自静态冻结常量
    /// `expectedTables(kind, schemaVersion: 1)`，counts 期望取自库内 slice_meta 自身
    /// （安装期已对已验签 manifest 做过三方核对，此处只防「拿错文件/被替换」）。
    public static func inspectSelfConsistent(path: String, kind: CatalogSliceKind,
                                             fileManager: FileManager = .default) -> State {
        guard fileManager.fileExists(atPath: path) else { return .missing }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = false
        configuration.busyMode = .timeout(1)
        let rows: [(key: String, value: String)]
        do {
            rows = try DatabaseQueue(path: path, configuration: configuration).read { db in
                try Row.fetchAll(db, sql: "SELECT key, value FROM slice_meta")
                    .map { (key: $0["key"] as String, value: $0["value"] as String) }
            }
        } catch {
            return .unreadable
        }
        let meta = Dictionary(rows.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        // The physical layout is stored inside the slice, so the probe no longer
        // hard-codes schemaVersion 1: catalog-v4 slices are layout 1, catalog-v7
        // slices are layout 3.
        let layout = meta["physical_schema"] ?? ""
        let schemaVersion: Int
        switch layout {
        case "catalog-v4": schemaVersion = 1
        case "catalog-v5": schemaVersion = 2
        case "catalog-v7": schemaVersion = 3
        case "catalog-v8": schemaVersion = 4
        default: return .contractViolation(.badValue("physical_schema"))
        }
        guard let tables = CatalogSliceManifestDecoder.expectedTables(kind, schemaVersion: schemaVersion) else {
            return .contractViolation(.badValue("tables"))
        }
        guard let raw = meta["counts"].flatMap({ $0.data(using: .utf8) }),
              let counts = try? JSONDecoder().decode([String: Int64].self, from: raw) else {   // try?-ok: 形态错按契约违规
            return .contractViolation(.badValue("counts"))
        }
        return inspect(path: path, kind: kind, schemaVersion: schemaVersion,
                       expectedTables: tables, expectedCounts: counts,
                       verifyCounts: true, fileManager: fileManager)
    }

    /// 每布局必须存在的列（缺列在安装期即拒绝，而不是等 App 查询时崩）。
    /// 2026-10-31：列此前完全不在契约链上——L0/manifest/探针全绿而 App 缺列。
    public static func requiredColumns(_ kind: CatalogSliceKind, schemaVersion: Int) -> [String: Set<String>] {
        switch (kind, schemaVersion) {
        case (.drug, 3):
            return [
                "drug": ["id", "region", "source_id", "name_zh", "usage_text", "indications"],
                "drug_package": ["drug_id", "source_id"],
                "drug_reference": ["reference_id", "drug_id", "image_urls_json", "match_status"],
                "leaflet_doc": ["doc_sha256", "text_zlib", "section_count", "text_bytes"],
                "leaflet_source": ["source_id", "doc_sha256", "source_url", "fetched_at"],
                "leaflet_section": ["doc_sha256", "ordinal", "kind", "char_start", "char_end"],
                "leaflet_link": ["source_id", "drug_id", "match_method", "match_verified"],
            ]
        case (.drug, 4):
            // v8 final: App SQL 静态引用列；其余列可缺值不可缺列（发布器校验）。
            return [
                "drug": ["id", "region", "source_id", "name_zh", "name_en", "brand_name",
                          "manufacturer", "insurance_code", "drug_code", "usage_text",
                          "indications"],
                "drug_reference": ["drug_id", "reference_id", "image_urls_json", "match_status"],
                "drug_sections": ["drug_id", "source_id", "field", "ordinal", "kind",
                                   "value", "content_sha256", "text_bytes"],
            ]
        case (.drug, 1):
            return ["drug": ["id", "region", "source_id", "name_zh"],
                    "drug_detail": ["region", "source_id", "usage_text", "indications"],
                    "drug_reference": ["reference_id", "region", "source_id", "match_status"]]
        default:
            return [:]
        }
    }

    /// `expectedTables`/`expectedCounts` 来自已验签 manifest（`CatalogSliceManifestDecoder`）；
    /// `verifyCounts` 由调用方决定：2026-10-28 U-批业主裁决 Q14=B——启动探测即全量
    /// （integrity/FK/逐表 COUNT），旧注释「启动只做元数据级」与实现不符已删。
    public static func inspect(path: String, kind: CatalogSliceKind, schemaVersion: Int,
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
                for (table, required) in Self.requiredColumns(kind, schemaVersion: schemaVersion) {
                    let present = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
                        .map { $0["name"] as String })
                    guard required.isSubset(of: present) else { return .tableSetMismatch }
                }
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
