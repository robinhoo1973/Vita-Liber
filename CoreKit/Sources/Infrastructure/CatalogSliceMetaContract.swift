import Foundation

/// 切片包内 `slice_meta` 契约（纯 Foundation 校验核心；GRDB 读取壳在 `CatalogSliceProbe`）。
///
/// 结构 = key/value 行（`key TEXT PRIMARY KEY`，f7 拆分器实样）。硬验键：
/// - `format` == `vita-liber-catalog-slice/v1`
/// - `dedupe` == `"1"`
/// - `physical_schema` ∈ {"catalog-v4"}（列契约版本：v5 布局旧 App 必须拒装，
///   靠 minApp 提示升级——加表/改列布局必须连同 schemaVersion/minAppBuild 升）
/// - `source_sha256` 形态 64 位小写 hex（**数值不作门**——源库不随包，App 无法验证）
/// - `tables` = JSON 数组（集合 == 已验签 manifest.tables；发布器按源序写入，不排序）
/// - `counts` = JSON 对象（== 已验签 manifest.counts；发布器 sort_keys 写入）
/// - `source_user_version` 形态整数（仅信息性）
///
/// 未知键一律忽略：语义变更必须走 `format`/`physical_schema` 取值变更，
/// 不靠「加键」演进（否则 f7 每加一个诊断键三片联动重签、旧 App 全线 fail-closed）。
public enum CatalogSliceMetaContract {
    public static let format = "vita-liber-catalog-slice/v1"
    public static let supportedPhysicalSchemas: Set<String> = ["catalog-v4"]
    public static let requiredKeys: Set<String> = [
        "format", "source_sha256", "dedupe", "tables", "counts",
        "physical_schema", "source_user_version",
    ]

    public enum Violation: Error, Equatable {
        case missingKey(String)
        case duplicateKey(String)
        case badValue(String)
        case tablesMismatch
        case countsMismatch
    }

    public struct Observed: Sendable, Equatable {
        public let sourceSHA256: String
        public let physicalSchema: String
        public let sourceUserVersion: Int64?
        public let tables: Set<String>
    }

    /// `rows`：slice_meta 全表；`expectedTables`/`expectedCounts` = 已验签 manifest 值。
    public static func validate(rows: [(key: String, value: String)],
                                expectedTables: Set<String>,
                                expectedCounts: [String: Int64]) throws -> Observed {
        var meta: [String: String] = [:]
        for row in rows {
            guard meta.updateValue(row.value, forKey: row.key) == nil else {
                throw Violation.duplicateKey(row.key)
            }
        }
        for key in requiredKeys where meta[key] == nil { throw Violation.missingKey(key) }
        guard meta["format"] == format else { throw Violation.badValue("format") }
        guard meta["dedupe"] == "1" else { throw Violation.badValue("dedupe") }
        let source = meta["source_sha256"] ?? ""
        guard MedicalCatalogReleaseProtocol.isLowercaseSHA256(source) else {
            throw Violation.badValue("source_sha256")
        }
        let physical = meta["physical_schema"] ?? ""
        guard supportedPhysicalSchemas.contains(physical) else {
            throw Violation.badValue("physical_schema")
        }
        let tables = try decodeJSON([String].self, meta["tables"] ?? "", key: "tables")
        guard Set(tables).count == tables.count, tables.allSatisfy({ !$0.isEmpty }) else {
            throw Violation.badValue("tables")
        }
        guard Set(tables) == expectedTables else { throw Violation.tablesMismatch }
        let counts = try decodeJSON([String: Int64].self, meta["counts"] ?? "", key: "counts")
        guard counts == expectedCounts, counts.values.allSatisfy({ $0 > 0 }) else {
            throw Violation.countsMismatch
        }
        // source_user_version 仅形态信息（v4 库 user_version，v5 将变化；不作身份）
        let userVersion = meta["source_user_version"].flatMap { Int64($0) }
        if let raw = meta["source_user_version"], userVersion == nil {
            throw Violation.badValue("source_user_version")
        }
        return Observed(sourceSHA256: source, physicalSchema: physical,
                        sourceUserVersion: userVersion, tables: Set(tables))
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, _ raw: String, key: String) throws -> T {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(T.self, from: data) else {   // try?-ok: 形态错即拒（badValue）
            throw Violation.badValue(key)
        }
        return value
    }
}
