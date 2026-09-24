#if os(iOS) || os(macOS)
// linux-blind: GRDB 四域只读池 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Domain
import Foundation
import GRDB

/// schema v4 四域参考数据（医院/科室/疾病/检查化验）的只读存取。
///
/// 独立于在途 `MedicalCatalogStore`（药品域）——各自持有 readonly DatabasePool
/// 打开同一 catalog 文件，本类型只做四域查询（新文件扩展，业主 2026-09-24 裁定）。
///
/// 版本门控：打开时读 `catalog_meta.schema_version`；< 4（纯药品 v3 包）时四域
/// API 全部降级返回空，不拒绝包、不抛错（旧包仍可被药品域使用）。
///
/// 检索纪律：目录数据为 B 级「目录参考」，联想绝不写入业务表（BR-003/004）；
/// LIKE 查询对 `%`/`_`/`\` 转义，前缀命中排在包含命中之前。

public actor MedicalReferenceCatalogStore: MedicalReferenceCatalogReading {
    /// 四域表首次出现的 catalog schema 版本（与 build_medical_data.sh v4 DDL 一致）。
    public static let schemaGateVersion = 4

    private let pool: DatabasePool
    private let gated: Bool

    public init(path: String) throws {
        var config = Configuration()
        config.readonly = true
        let pool = try DatabasePool(path: path, configuration: config)
        self.pool = pool
        let version = try pool.read { db in
            try Int(String.fetchOne(db, sql: "SELECT value FROM catalog_meta WHERE key = 'schema_version'")) ?? 0
        }
        self.gated = version < Self.schemaGateVersion
    }

    public var catalogSchemaVersion: Int {
        get async throws {
            try await pool.read { db in
                try Int(String.fetchOne(db, sql: "SELECT value FROM catalog_meta WHERE key = 'schema_version'")) ?? 0
            }
        }
    }

    // MARK: - 查询

    public func hospitalSuggest(query: String, region: String?, limit: Int) async throws -> [MedicalCatalogHospital] {
        guard !gated else { return [] }
        let q = Self.likeEscaped(query)
        guard !q.isEmpty else { return [] }
        let prefix = q + "%"
        let contains = "%" + q + "%"
        let rows = try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rowid, region, source_id, code, name_zh, short_name, type_zh, level_zh, address,
                       phone, admin_area, depts_json, aliases_json, contract_end
                FROM hospital
                WHERE (?1 IS NULL OR region = ?1)
                  AND (name_zh LIKE ?2 ESCAPE '\\' OR short_name LIKE ?2 ESCAPE '\\'
                       OR name_zh LIKE ?3 ESCAPE '\\' OR short_name LIKE ?3 ESCAPE '\\' OR aliases_json LIKE ?3 ESCAPE '\\')
                ORDER BY (name_zh LIKE ?2 ESCAPE '\\' OR short_name LIKE ?2 ESCAPE '\\') DESC, region, name_zh
                LIMIT ?4
                """, arguments: [region, prefix, contains, Self.clamped(limit)])
        }
        return try rows.map(Self.hospital(from:))
    }

    public func departmentList(region: String?) async throws -> [MedicalCatalogDepartment] {
        guard !gated else { return [] }
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

    public func diagnosisSuggest(query: String, system: String?, region: String?, limit: Int) async throws -> [MedicalCatalogDiagnosis] {
        guard !gated else { return [] }
        let q = Self.likeEscaped(query)
        guard !q.isEmpty else { return [] }
        let prefix = q + "%"
        let contains = "%" + q + "%"
        let rows = try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rowid, region, source_id, code, name_zh, code_system, chapter_zh, aliases_json
                FROM diagnosis
                WHERE (?1 IS NULL OR code_system = ?1)
                  AND (?2 IS NULL OR region = ?2)
                  AND (code LIKE ?3 ESCAPE '\\' OR name_zh LIKE ?4 ESCAPE '\\' OR aliases_json LIKE ?4 ESCAPE '\\')
                ORDER BY (code LIKE ?3 ESCAPE '\\') DESC, region, code
                LIMIT ?5
                """, arguments: [system, region, prefix, contains, Self.clamped(limit)])
        }
        return try rows.map(Self.diagnosis(from:))
    }

    public func examSuggest(query: String, category: String?, region: String?, limit: Int) async throws -> [MedicalCatalogExamItem] {
        guard !gated else { return [] }
        let q = Self.likeEscaped(query)
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
                       OR aliases_json LIKE ?4 ESCAPE '\\')
                ORDER BY (code LIKE ?3 ESCAPE '\\') DESC, region, code
                LIMIT ?5
                """, arguments: [category, region, prefix, contains, Self.clamped(limit)])
        }
        return try rows.map(Self.exam(from:))
    }

    // MARK: - 内助

    /// LIKE 模式转义：`\` `%` `_` 按 ESCAPE '\' 语义先行转义（DDL 查询统一 ESCAPE）。
    static func likeEscaped(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            if c == "\\" || c == "%" || c == "_" {
                out.append("\\")
            }
            out.append(c)
        }
        return out
    }

    static func clamped(_ limit: Int) -> Int { max(1, min(limit, 100)) }

    static func hospital(from row: Row) throws -> MedicalCatalogHospital {
        MedicalCatalogHospital(
            id: row["rowid"], region: row["region"], sourceID: row["source_id"], code: row["code"],
            nameZh: row["name_zh"], shortName: row["short_name"], typeZh: row["type_zh"],
            levelZh: row["level_zh"], address: row["address"], phone: row["phone"],
            adminArea: row["admin_area"], deptsJSON: row["depts_json"], aliasesJSON: row["aliases_json"],
            contractEnd: row["contract_end"])
    }

    static func department(from row: Row) throws -> MedicalCatalogDepartment {
        MedicalCatalogDepartment(
            id: row["rowid"], region: row["region"], sourceID: row["source_id"], code: row["code"],
            nameZh: row["name_zh"], categoryZh: row["category_zh"], aliasesJSON: row["aliases_json"])
    }

    static func diagnosis(from row: Row) throws -> MedicalCatalogDiagnosis {
        MedicalCatalogDiagnosis(
            id: row["rowid"], region: row["region"], sourceID: row["source_id"], code: row["code"],
            nameZh: row["name_zh"], codeSystem: row["code_system"], chapterZh: row["chapter_zh"],
            aliasesJSON: row["aliases_json"])
    }

    static func exam(from row: Row) throws -> MedicalCatalogExamItem {
        MedicalCatalogExamItem(
            id: row["rowid"], region: row["region"], sourceID: row["source_id"], code: row["code"],
            nameZh: row["name_zh"], nameEn: row["name_en"], category: row["category"],
            method: row["method"], specimen: row["specimen"], unit: row["unit"],
            priceRef: row["price_ref"], loincConceptID: row["loinc_concept_id"], aliasesJSON: row["aliases_json"])
    }
}
#endif
