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

    public static func integrityCheck(path: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let pool = try DatabasePool(path: path.path, configuration: configuration)
        let result = try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check")
        }
        guard result == "ok" else { throw MedicalCatalogUpdateError.catalogIntegrityFailed }
    }

    public init(path: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        pool = try DatabasePool(path: path.path, configuration: configuration)
    }

    public func match(line: PrescriptionLine) async throws -> MedicalCatalogMatch {
        try pool.read { db in
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
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT reference_id, region, source_id, license_no, name_zh, name_en, brand_name,
                       spec_raw, image_urls_json, match_status
                FROM drug_reference WHERE source_id = ? ORDER BY reference_id
                """, arguments: [drug.sourceID]).map(Self.reference)
        }
    }

    public func detail(for drug: MedicalCatalogDrug) async throws -> MedicalCatalogDrugDetail? {
        try pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT region, source_id, usage_text, indications, active_ingredients,
                       usage_ref_json, raw_json
                FROM drug_detail WHERE region = ? AND source_id = ?
                """, arguments: [drug.region, drug.sourceID]).map(Self.detail)
        }
    }

    public func drug(id: Int) async throws -> MedicalCatalogDrug? {
        try pool.read { db in
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
