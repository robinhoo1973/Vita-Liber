#if os(iOS) || os(macOS)
// linux-blind: GRDB 四域只读池 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Domain
import Foundation
import GRDB

/// 诊断/检查切片只读仓（`app-catalog-reference.sqlite`：diagnosis + exam_item）。
///
/// 查询面与 v4 `MedicalReferenceCatalogStore` 对应方法逐字一致（同 DDL 源）；
/// 发布门 = 切片自洽校验（同 facility store）。检索纪律不变：LIKE 转义、
/// 前缀命中优先、联想绝不写业务表（BR-003/004）。
public final class CatalogSliceExamStore: MedicalExamCatalogReading, @unchecked Sendable {
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

    public func diagnosisSuggest(query: String, system: String?, region: String?, limit: Int) async throws -> [MedicalCatalogDiagnosis] {
        let q = MedicalReferenceCatalogStore.likeEscaped(query)
        guard !q.isEmpty else { return [] }
        let prefix = q + "%"
        let contains = "%" + q + "%"
        let rows = try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rowid, region, source_id, code, name_zh, code_system, chapter_zh, aliases_json
                FROM diagnosis
                WHERE (?1 IS NULL OR code_system = ?1)
                  AND (?2 IS NULL OR region = ?2)
                  AND (code LIKE ?3 ESCAPE '\\' OR name_zh LIKE ?4 ESCAPE '\\'
                       OR \(Self.aliasContainsSQL(parameter: 4)))
                ORDER BY (code LIKE ?3 ESCAPE '\\') DESC, region, code
                LIMIT ?5
                """, arguments: [system, region, prefix, contains, Self.clamped(limit)])
        }
        return try rows.map(Self.diagnosis(from:))
    }

    public func examSuggest(query: String, category: String?, region: String?, limit: Int) async throws -> [MedicalCatalogExamItem] {
        let q = MedicalReferenceCatalogStore.likeEscaped(query)
        guard !q.isEmpty else { return [] }
        let prefix = q + "%"
        let contains = "%" + q + "%"
        let rows = try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rowid, region, source_id, code, name_zh, name_en, category, method, specimen, unit,
                       price_ref, loinc_concept_id, aliases_json
                FROM exam_item
                WHERE (?1 IS NULL OR category = ?1)
                  AND (?2 IS NULL OR region = ?2)
                  AND (code LIKE ?3 ESCAPE '\\' OR name_zh LIKE ?4 ESCAPE '\\' OR name_en LIKE ?4 ESCAPE '\\'
                       OR \(Self.aliasContainsSQL(parameter: 4)))
                ORDER BY (code LIKE ?3 ESCAPE '\\') DESC, region, code
                LIMIT ?5
                """, arguments: [category, region, prefix, contains, Self.clamped(limit)])
        }
        return try rows.map(Self.exam(from:))
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

    private static func diagnosis(from row: Row) throws -> MedicalCatalogDiagnosis {
        MedicalCatalogDiagnosis(
            id: row["rowid"], region: row["region"], sourceID: row["source_id"], code: row["code"],
            nameZh: row["name_zh"], codeSystem: row["code_system"], chapterZh: row["chapter_zh"],
            aliasesJSON: row["aliases_json"])
    }

    private static func exam(from row: Row) throws -> MedicalCatalogExamItem {
        MedicalCatalogExamItem(
            id: row["rowid"], region: row["region"], sourceID: row["source_id"], code: row["code"],
            nameZh: row["name_zh"], nameEn: row["name_en"], category: row["category"],
            method: row["method"], specimen: row["specimen"], unit: row["unit"],
            priceRef: row["price_ref"], loincConceptID: row["loinc_concept_id"], aliasesJSON: row["aliases_json"])
    }
}
#endif
