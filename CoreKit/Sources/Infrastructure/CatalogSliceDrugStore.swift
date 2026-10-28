#if os(iOS) || os(macOS)
// linux-blind: GRDB 只读池/目录匹配 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Domain
import Foundation
import GRDB

/// 药品切片只读仓（`app-catalog-drug.sqlite`）。
///
/// 查询面与 v4 `MedicalCatalogStore` 逐字一致（同 DDL 源：drug/drug_detail/
/// drug_reference）；发布门换成切片契约：
/// - 构造期自洽校验 `slice_meta`（format/dedupe/physical_schema/source_sha256 形态 +
///   tables/counts 与自身声明一致）——安装期 `CatalogSliceProbe` 已对已验签 manifest
///   做过三方核对（含 COUNT(*)），此处只防「拿错文件/被替换」；
/// - 不读 `catalog_meta`/`user_version`（切片没有这些键）。
public final class CatalogSliceDrugStore: MedicalCatalogReading, @unchecked Sendable {
    public let sqliteSHA256: String
    public let sliceMeta: CatalogSliceMetaContract.Observed
    private let pool: DatabasePool

    public init(path: URL) throws {
        let observed = try Self.inspectSliceMeta(path: path)
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        let opened = try DatabasePool(path: path.path, configuration: configuration)
        self.pool = opened
        self.sliceMeta = observed
        self.sqliteSHA256 = try StreamingFileHasher.sha256(of: path)
    }

    /// 自洽校验（非 manifest 对账）：tables/counts 期望值取自 slice_meta 自身。
    static func inspectSliceMeta(path: URL) throws -> CatalogSliceMetaContract.Observed {
        var configuration = Configuration()
        configuration.readonly = true
        let rows: [(key: String, value: String)] = try DatabaseQueue(path: path.path,
                                                                     configuration: configuration).read { db in
            try Row.fetchAll(db, sql: "SELECT key, value FROM slice_meta")
                .map { (key: $0["key"] as String, value: $0["value"] as String) }
        }
        let meta = Dictionary(rows.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        guard let tablesJSON = meta["tables"], let countsJSON = meta["counts"],
              let tablesData = tablesJSON.data(using: .utf8),
              let countsData = countsJSON.data(using: .utf8),
              let tables = try? JSONDecoder().decode([String].self, from: tablesData),   // try?-ok: 形态错按不可用
              let counts = try? JSONDecoder().decode([String: Int64].self, from: countsData) else {   // try?-ok: 同上
            throw CatalogSliceMetaContract.Violation.badValue("tables")
        }
        return try CatalogSliceMetaContract.validate(rows: rows,
                                                     expectedTables: Set(tables),
                                                     expectedCounts: counts)
    }

    public var catalogGeneration: UInt64 { 0 }

    // MARK: - 查询（与 v4 MedicalCatalogStore 同口径）

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
            let like = "%" + CatalogSQLLike.escaped(name) + "%"
            var candidates = try Self.rows(db, sql: """
                SELECT * FROM drug
                WHERE name_zh = ? OR name_en = ? OR brand_name = ?
                   OR name_zh LIKE ? ESCAPE '\\' OR name_en LIKE ? ESCAPE '\\' OR brand_name LIKE ? ESCAPE '\\'
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
                FROM drug_reference WHERE region = ? AND source_id = ? ORDER BY reference_id
                """, arguments: [drug.region, drug.sourceID]).map(Self.reference)
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

    // MARK: - 行映射（与 v4 同口径）

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
