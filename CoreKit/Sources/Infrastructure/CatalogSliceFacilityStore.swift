#if os(iOS) || os(macOS)
// linux-blind: GRDB 四域只读池 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Domain
import Foundation
import GRDB

/// 医院/科室切片只读仓（`app-catalog-facility.sqlite`：hospital + department）。
///
/// 查询面与 v4 `MedicalReferenceCatalogStore` 对应方法逐字一致（同 DDL 源）；
/// 发布门 = 切片自洽校验（slice_meta format/dedupe/physical_schema + 自身
/// tables/counts 一致），安装期已由 `CatalogSliceProbe` 对已验签 manifest 三方核对。
/// 检索纪律不变：LIKE 转义、前缀命中优先、联想绝不写业务表（BR-003/004）。
public final class CatalogSliceFacilityStore: MedicalFacilityCatalogReading, @unchecked Sendable {
    public let sqliteSHA256: String
    public let sliceMeta: CatalogSliceMetaContract.Observed
    private let pool: DatabasePool

    public init(path: URL) throws {
        let observed = try CatalogSliceDrugStore.inspectSliceMeta(path: path)
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        self.pool = try DatabasePool(path: path.path, configuration: configuration)
        self.sliceMeta = observed
        self.sqliteSHA256 = try StreamingFileHasher.sha256(of: path)
    }

    public var catalogGeneration: UInt64 { 0 }

    // MARK: - 查询（与 v4 同口径）

    public func hospitalSuggest(query: String, region: String?, limit: Int) async throws -> [MedicalCatalogHospital] {
        let q = CatalogSQLLike.escaped(query)
        guard !q.isEmpty else { return [] }
        let prefix = q + "%"
        let contains = "%" + q + "%"
        let rows = try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rowid, region, source_id, code, name_zh, short_name, type_zh, level_zh, address,
                       phone, admin_area, depts_json, aliases_json
                FROM hospital
                WHERE (?1 IS NULL OR region = ?1)
                  AND (name_zh LIKE ?2 ESCAPE '\\' OR short_name LIKE ?2 ESCAPE '\\'
                       OR name_zh LIKE ?3 ESCAPE '\\' OR short_name LIKE ?3 ESCAPE '\\'
                       OR \(Self.aliasContainsSQL(parameter: 3)))
                ORDER BY (name_zh LIKE ?2 ESCAPE '\\' OR short_name LIKE ?2 ESCAPE '\\') DESC, region, name_zh
                LIMIT ?4
                """, arguments: [region, prefix, contains, Self.clamped(limit)])
        }
        return try rows.map(Self.hospital(from:))
    }

    public func departmentList(region: String?) async throws -> [MedicalCatalogDepartment] {
        let rows = try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rowid, region, source_id, code, name_zh, category_zh, aliases_json
                FROM department
                WHERE (?1 IS NULL OR region = ?1)
                ORDER BY region, code
                LIMIT 2000
                """, arguments: [region])
        }
        return try rows.map(Self.department(from:))
    }

    // MARK: - 内助（与 v4 同口径）

    private static func aliasContainsSQL(parameter: Int) -> String {
        """
        EXISTS (
            SELECT 1 FROM json_each(
                CASE WHEN json_valid(aliases_json) THEN
                    CASE WHEN json_type(aliases_json)='array' THEN aliases_json ELSE '[]' END
                ELSE '[]' END
            ) AS catalog_alias
            WHERE CASE catalog_alias.type
                WHEN 'text' THEN catalog_alias.atom
                WHEN 'object' THEN CASE WHEN json_type(catalog_alias.value,'$.text')='text'
                    THEN json_extract(catalog_alias.value,'$.text') END
            END LIKE ?\(parameter) ESCAPE '\\'
        )
        """
    }

    private static func clamped(_ limit: Int) -> Int { max(1, min(limit, 100)) }

    private static func hospital(from row: Row) throws -> MedicalCatalogHospital {
        MedicalCatalogHospital(
            id: row["rowid"], region: row["region"], sourceID: row["source_id"], code: row["code"],
            nameZh: row["name_zh"], shortName: row["short_name"], typeZh: row["type_zh"],
            levelZh: row["level_zh"], address: row["address"], phone: row["phone"],
            adminArea: row["admin_area"], deptsJSON: row["depts_json"], aliasesJSON: row["aliases_json"])
    }

    private static func department(from row: Row) throws -> MedicalCatalogDepartment {
        MedicalCatalogDepartment(
            id: row["rowid"], region: row["region"], sourceID: row["source_id"], code: row["code"],
            nameZh: row["name_zh"], categoryZh: row["category_zh"], aliasesJSON: row["aliases_json"])
    }
}
#endif
