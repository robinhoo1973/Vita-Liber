#if os(iOS) || os(macOS)
// linux-blind: GRDB 只读池 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Domain
import Foundation
import GRDB

/// profile 第四切片只读仓（`app-profile-chronic_surgery.sqlite`，2026-10-28 P-批）。
///
/// 医疗档案选择器的目录事实来源（`MedicalProfileCatalogReading`）：
/// - 构造期自洽校验 `slice_meta`（复用 `CatalogSliceDrugStore.inspectSliceMeta`
///   同口径：format/dedupe/physical_schema/source_sha256 形态 + tables/counts
///   与自身声明一致）——安装期 `CatalogSliceProbe` 已对已验签 manifest 做过
///   三方核对（含 COUNT(*)），此处只防「拿错文件/被替换」；
/// - **只读基表，不读视图**（`active_*`/`published_top10` 不入切片契约，
///   且丢失 `rank_basis`/报告字段）；
/// - 谓词纪律：region + `active=1` + 关联表 `review_status='approved'`；
/// - 缺片/损坏由 facade 层抛 `.unavailable`（本类型只在打开成功后被提交）。
public final class CatalogSliceProfileStore: MedicalProfileCatalogReading, @unchecked Sendable {
    public let sqliteSHA256: String
    public let sliceMeta: CatalogSliceMetaContract.Observed
    private let pool: DatabasePool

    public init(path: URL) throws {
        let observed = try CatalogSliceDrugStore.inspectSliceMeta(path: path)
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        let opened = try DatabasePool(path: path.path, configuration: configuration)
        self.pool = opened
        self.sliceMeta = observed
        self.sqliteSHA256 = try StreamingFileHasher.sha256(of: path)
    }

    // MARK: - 读面（快照；13 表约 800 行，一次取全便于代际 fencing）

    public func profileSnapshot(region: String) async throws -> MedicalProfileCatalogSnapshot {
        do {
            return try await pool.read { db in
                let conditions = try Row.fetchAll(db, sql: """
                    SELECT app_catalog_id, region, official_name, display_name, code,
                           code_system, code_version, code_status, item_nature,
                           body_region_id, aliases_json
                    FROM condition_profile
                    WHERE region = ? AND active = 1
                    ORDER BY display_name
                    """, arguments: [region]).map(Self.condition)
                let surgeries = try Row.fetchAll(db, sql: """
                    SELECT app_catalog_id, region, name_zh, code, code_system,
                           code_version, code_status, body_region_id, aliases_json
                    FROM surgery
                    WHERE region = ? AND active = 1
                    ORDER BY name_zh
                    """, arguments: [region]).map(Self.surgery)
                let organs = try Row.fetchAll(db, sql: """
                    SELECT organ_id, region, name_zh, body_region_id, sort_order
                    FROM body_organ
                    WHERE region = ?
                    ORDER BY sort_order, organ_id
                    """, arguments: [region]).map(Self.organ)
                let departments = try Row.fetchAll(db, sql: """
                    SELECT code, region, official_name, category_zh
                    FROM ext_department
                    WHERE region = ?
                    ORDER BY official_name
                    """, arguments: [region]).map(Self.department)
                let conditionDepartments = try Row.fetchAll(db, sql: """
                    SELECT cp.app_catalog_id AS subject_id, d.code AS department_code,
                           cd.role, cd.derivation
                    FROM condition_department cd
                    JOIN condition_profile cp ON cp.condition_uid = cd.condition_uid
                    JOIN ext_department d ON d.department_uid = cd.department_uid
                    WHERE cd.active = 1 AND cd.review_status = 'approved' AND cd.region = ?
                    ORDER BY cp.app_catalog_id, d.code
                    """, arguments: [region]).map(Self.departmentLink)
                let surgeryDepartments = try Row.fetchAll(db, sql: """
                    SELECT s.app_catalog_id AS subject_id, d.code AS department_code,
                           sd.role, sd.derivation
                    FROM surgery_department sd
                    JOIN surgery s ON s.surgery_uid = sd.surgery_uid
                    JOIN ext_department d ON d.department_uid = sd.department_uid
                    WHERE sd.active = 1 AND sd.review_status = 'approved' AND sd.region = ?
                    ORDER BY s.app_catalog_id, d.code
                    """, arguments: [region]).map(Self.departmentLink)
                let conditionOrgans = try Row.fetchAll(db, sql: """
                    SELECT cp.app_catalog_id AS subject_id, o.organ_id,
                           co.role, co.derivation, co.confidence
                    FROM condition_organ co
                    JOIN condition_profile cp ON cp.condition_uid = co.condition_uid
                    JOIN body_organ o ON o.organ_uid = co.organ_uid
                    WHERE co.active = 1 AND co.review_status = 'approved' AND co.region = ?
                    ORDER BY cp.app_catalog_id, co.role, o.sort_order
                    """, arguments: [region]).map(Self.organLink)
                let surgeryOrgans = try Row.fetchAll(db, sql: """
                    SELECT s.app_catalog_id AS subject_id, o.organ_id,
                           so.role, so.derivation, so.confidence
                    FROM surgery_organ so
                    JOIN surgery s ON s.surgery_uid = so.surgery_uid
                    JOIN body_organ o ON o.organ_uid = so.organ_uid
                    WHERE so.active = 1 AND so.review_status = 'approved' AND so.region = ?
                    ORDER BY s.app_catalog_id, so.role, o.sort_order
                    """, arguments: [region]).map(Self.organLink)
                let conditionRanks = try Row.fetchAll(db, sql: """
                    SELECT 'condition' AS subject_kind, cp.app_catalog_id AS subject_id,
                           r.region, r.rank, r.rank_total, r.metric, r.rank_basis,
                           r.value, r.unit, r.report_year, r.report_title, r.publisher
                    FROM common_rank r
                    JOIN condition_profile cp ON cp.condition_uid = r.subject_uid
                    WHERE r.subject_kind = 'condition' AND r.region = ?
                      AND r.active = 1 AND r.review_status = 'approved'
                    ORDER BY r.rank
                    """, arguments: [region]).map(Self.rank)
                let surgeryRanks = try Row.fetchAll(db, sql: """
                    SELECT 'surgery' AS subject_kind, s.app_catalog_id AS subject_id,
                           r.region, r.rank, r.rank_total, r.metric, r.rank_basis,
                           r.value, r.unit, r.report_year, r.report_title, r.publisher
                    FROM common_rank r
                    JOIN surgery s ON s.surgery_uid = r.subject_uid
                    WHERE r.subject_kind = 'surgery' AND r.region = ?
                      AND r.active = 1 AND r.review_status = 'approved'
                    ORDER BY r.rank
                    """, arguments: [region]).map(Self.rank)
                return MedicalProfileCatalogSnapshot(
                    region: region, conditions: conditions, surgeries: surgeries,
                    organs: organs, departments: departments,
                    conditionDepartments: conditionDepartments,
                    surgeryDepartments: surgeryDepartments,
                    conditionOrgans: conditionOrgans, surgeryOrgans: surgeryOrgans,
                    conditionRanks: conditionRanks, surgeryRanks: surgeryRanks)
            }
        } catch let error as MedicalProfileCatalogFailure {
            throw error
        } catch {
            throw MedicalProfileCatalogFailure.invalidData
        }
    }

    // MARK: - 行映射

    private static func aliases(_ row: Row) -> [String] {
        guard let raw: String = row["aliases_json"],
              let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode([String].self, from: data) else {   // try?-ok: 坏形按空别名
            return []
        }
        return value
    }

    private static func condition(_ row: Row) -> MedicalProfileCondition {
        MedicalProfileCondition(
            catalogID: row["app_catalog_id"], region: row["region"],
            officialName: row["official_name"], displayName: row["display_name"],
            code: row["code"], codeSystem: row["code_system"], codeVersion: row["code_version"],
            codeStatus: row["code_status"], itemNature: row["item_nature"],
            bodyRegionID: row["body_region_id"], aliases: aliases(row))
    }

    private static func surgery(_ row: Row) -> MedicalProfileSurgery {
        MedicalProfileSurgery(
            catalogID: row["app_catalog_id"], region: row["region"], nameZh: row["name_zh"],
            code: row["code"], codeSystem: row["code_system"], codeVersion: row["code_version"],
            codeStatus: row["code_status"], bodyRegionID: row["body_region_id"],
            aliases: aliases(row))
    }

    private static func organ(_ row: Row) -> MedicalProfileOrgan {
        MedicalProfileOrgan(
            organID: row["organ_id"], region: row["region"], nameZh: row["name_zh"],
            bodyRegionID: row["body_region_id"], sortOrder: row["sort_order"])
    }

    private static func department(_ row: Row) -> MedicalProfileDepartment {
        MedicalProfileDepartment(
            code: row["code"], region: row["region"],
            officialName: row["official_name"], categoryZh: row["category_zh"])
    }

    private static func departmentLink(_ row: Row) -> MedicalProfileDepartmentLink {
        MedicalProfileDepartmentLink(
            subjectCatalogID: row["subject_id"], departmentCode: row["department_code"],
            role: row["role"], derivation: row["derivation"])
    }

    private static func organLink(_ row: Row) -> MedicalProfileOrganLink {
        MedicalProfileOrganLink(
            subjectCatalogID: row["subject_id"], organID: row["organ_id"],
            role: row["role"], derivation: row["derivation"], confidence: row["confidence"])
    }

    private static func rank(_ row: Row) -> MedicalProfileRank {
        MedicalProfileRank(
            subjectKind: row["subject_kind"], subjectCatalogID: row["subject_id"],
            region: row["region"], rank: row["rank"], rankTotal: row["rank_total"],
            metric: row["metric"], rankBasis: row["rank_basis"],
            value: row["value"], unit: row["unit"], reportYear: row["report_year"],
            reportTitle: row["report_title"], publisher: row["publisher"])
    }
}
#endif
