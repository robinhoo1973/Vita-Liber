#if os(iOS) || os(macOS)
// linux-blind: GRDB 只读池/目录匹配 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain

/// 独立药品 SQLite 只读仓。
///
/// 该库不进入患者主库的迁移/WAL/备份事务；更新时由外部服务生成新文件并原子替换，
/// 本类型只负责并发读与匹配，不写 medication_id、不修改处方事实。
public final class MedicalCatalogStore: MedicalCatalogReading, @unchecked Sendable {
    private let pool: DatabasePool

    /// 解密后 SQLite 的发布门（镜像 Go `GateSQLite`）：SQLite 头、`integrity_check`、
    /// `foreign_key_check`、`user_version` 与 `catalog_meta` 的 schema/data 身份须等于已签字段。
    public static func validateRelease(path: URL, schemaVersion: Int, dataVersion: String) throws {
        let header = Data("SQLite format 3\u{0}".utf8)
        do {
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() } // try?-ok: 只读句柄关闭失败由系统回收
            guard try handle.read(upToCount: header.count) == header else {
                throw MedicalCatalogUpdateError.catalogIntegrityFailed
            }
        }
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: path.path, configuration: configuration)
        let passed = try queue.read { db -> Bool in
            guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok",
                  try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil,
                  try Int.fetchOne(db, sql: "PRAGMA user_version") == schemaVersion else { return false }
            let meta = try metadata(db)
            return meta.schemaVersion == schemaVersion && meta.dataVersion == dataVersion
        }
        guard passed else { throw MedicalCatalogUpdateError.catalogIntegrityFailed }
    }

    /// 代表性查询：按 App 实际读路径（只读 pool）复开，读目录元数据与 drug 首行。
    public static func smokeCheck(path: URL) throws {
        let store = try MedicalCatalogStore(path: path)
        let hasDrug = try store.pool.read { db -> Bool in
            _ = try metadata(db)
            return try Row.fetchOne(db, sql: """
                SELECT id, region, source_id, name_zh, usage_ref_json FROM drug ORDER BY id LIMIT 1
                """) != nil
        }
        guard hasDrug else { throw MedicalCatalogUpdateError.catalogIntegrityFailed }
    }

    /// 单次只读打开的完整发布门（2026-09-26 审查合并）：SQLite 头 + `integrity_check`
    /// + `foreign_key_check` + user_version/schema/dataVersion 元数据 + drug 代表性行。
    /// 原 `validateRelease` + `smokeCheck` 分两次打开同一文件、整库扫描跑两遍——
    /// 安装链路每个候选白白多一次全量页扫描 + 一次连接建立；合并后安装前验证
    /// 一次打开跑完（激活后 `activeCheck` 仍按最终路径复验，安全性不变）。
    public static func validateReleaseAndSmoke(path: URL, schemaVersion: Int, dataVersion: String) throws {
        let header = Data("SQLite format 3\u{0}".utf8)
        do {
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() } // try?-ok: 只读句柄关闭失败由系统回收
            guard try handle.read(upToCount: header.count) == header else {
                throw MedicalCatalogUpdateError.catalogIntegrityFailed
            }
        }
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: path.path, configuration: configuration)
        let passed = try queue.read { db -> Bool in
            guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok",
                  try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil,
                  try Int.fetchOne(db, sql: "PRAGMA user_version") == schemaVersion else { return false }
            let meta = try metadata(db)
            guard meta.schemaVersion == schemaVersion && meta.dataVersion == dataVersion else { return false }
            return try Row.fetchOne(db, sql: """
                SELECT id, region, source_id, name_zh, usage_ref_json FROM drug ORDER BY id LIMIT 1
                """) != nil
        }
        guard passed else { throw MedicalCatalogUpdateError.catalogIntegrityFailed }
    }

    public static func installedVersion(path: URL) throws -> MedicalCatalogInstalledVersion {
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: path.path, configuration: configuration).read(metadata)
    }

    private static func metadata(_ db: Database) throws -> MedicalCatalogInstalledVersion {
        let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM catalog_meta WHERE key IN ('schema_version', 'data_version')")
        var values: [String: String] = [:]
        for row in rows {
            let key: String = row["key"]
            let value: String = row["value"]
            values[key] = value
        }
        guard let schema = values["schema_version"].flatMap(Int.init), let data = values["data_version"] else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        return MedicalCatalogInstalledVersion(schemaVersion: schema, dataVersion: data)
    }

    public init(path: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        pool = try DatabasePool(path: path.path, configuration: configuration)
    }

    public func match(line: PrescriptionLine) async throws -> MedicalCatalogMatch {
        try await pool.read { db in
            let codeValues = [line.insuranceCode, line.itemCodeText].compactMap { $0 }.filter { !$0.isEmpty }
            var exact: [MedicalCatalogDrug] = []
            if !codeValues.isEmpty {
                let placeholders = Array(repeating: "?", count: codeValues.count).joined(separator: ",")
                let args = StatementArguments(codeValues + codeValues + codeValues)
                exact = try Self.rows(db, sql: """
                    SELECT * FROM drug
                    WHERE insurance_code IN (\(placeholders))
                       OR drug_code IN (\(placeholders))
                       OR source_id IN (\(placeholders))
                    ORDER BY id LIMIT 20
                    """, arguments: args)
            }
            if !exact.isEmpty {
                return MedicalCatalogMatching.resolve(exact: exact, candidates: [])
            }

            let name = line.printedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return MedicalCatalogMatch(status: .unmatched, exact: nil, candidates: [])
            }
            let like = "%" + name + "%"
            var candidates = try Self.rows(db, sql: """
                SELECT * FROM drug
                WHERE name_zh = ? OR name_en = ? OR brand_name = ?
                   OR name_zh LIKE ? OR name_en LIKE ? OR brand_name LIKE ?
                ORDER BY id LIMIT 50
                """, arguments: [name, name, name, like, like, like])
            if let spec = line.spec?.trimmingCharacters(in: .whitespacesAndNewlines), !spec.isEmpty {
                let specCandidates = candidates.filter { $0.spec == spec }
                if !specCandidates.isEmpty { candidates = specCandidates }
            }
            return MedicalCatalogMatching.resolve(exact: [], candidates: candidates)
        }
    }

    public func reference(for drug: MedicalCatalogDrug) async throws -> [MedicalCatalogReference] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT reference_id, region, source_id, license_no, name_zh, name_en, brand_name,
                       spec_raw, image_urls_json, match_status
                FROM drug_reference WHERE source_id = ? ORDER BY reference_id
                """, arguments: [drug.sourceID]).map(Self.reference)
        }
    }

    public func detail(for drug: MedicalCatalogDrug) async throws -> MedicalCatalogDrugDetail? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT region, source_id, usage_text, indications, active_ingredients,
                       usage_ref_json, raw_json
                FROM drug_detail WHERE region = ? AND source_id = ?
                """, arguments: [drug.region, drug.sourceID]).map(Self.detail)
        }
    }

    public func drug(id: Int) async throws -> MedicalCatalogDrug? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM drug WHERE id = ?", arguments: [id]).map(Self.drug)
        }
    }

    private static func rows(_ db: Database, sql: String, arguments: StatementArguments) throws -> [MedicalCatalogDrug] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map(drug)
    }

    private static func drug(_ row: Row) -> MedicalCatalogDrug {
        MedicalCatalogDrug(
            id: row["id"], region: row["region"], sourceID: row["source_id"], licenseNo: row["license_no"],
            nameZh: row["name_zh"], nameEn: row["name_en"], brandName: row["brand_name"],
            dosageForm: row["dosage_form"], spec: row["spec"], drugCategory: row["drug_category"],
            licenseHolder: row["license_holder"], manufacturer: row["manufacturer"],
            insuranceCode: row["insurance_code"], drugCode: row["drug_code"],
            activeIngredients: row["active_ingredients"], usageReferenceJSON: row["usage_ref_json"] ?? "{}")
    }

    private static func reference(_ row: Row) -> MedicalCatalogReference {
        MedicalCatalogReference(
            referenceID: row["reference_id"], region: row["region"], sourceID: row["source_id"],
            licenseNo: row["license_no"], nameZh: row["name_zh"], nameEn: row["name_en"],
            brandName: row["brand_name"], specificationRaw: row["spec_raw"],
            imageURLsJSON: row["image_urls_json"] ?? "[]",
            matchStatus: MedicalCatalogMatchStatus(rawValue: row["match_status"] ?? "unmatched") ?? .unmatched)
    }

    private static func detail(_ row: Row) -> MedicalCatalogDrugDetail {
        MedicalCatalogDrugDetail(
            region: row["region"], sourceID: row["source_id"], usageText: row["usage_text"],
            indications: row["indications"], activeIngredients: row["active_ingredients"],
            usageReferenceJSON: row["usage_ref_json"] ?? "{}", rawJSON: row["raw_json"] ?? "{}")
    }
}
#endif
