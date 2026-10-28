import Foundation

/// 医疗档案目录读端口（profile 第四切片；2026-10-28 P-批，业主定案）。
///
/// 患者档案选择器（慢性病/手术选择、科室/器官展示）的**目录事实来源**：
/// 生产实现 = `ProfileSliceStore`（Infrastructure，GRDB 只读，读 profile 切片
/// 基表）；缺片/损坏由实现抛 `.unavailable`——**不返回空集、不回落内嵌目录**
/// （`HealthHistoryCatalog` 仅保留给历史迁移 v47/v48 与旧行展示快照）。
///
/// 读面纪律：
/// - 只读基表，不读视图（`active_*`/`published_top10` 不入切片契约，且丢失
///   `rank_basis`/报告字段）；
/// - 纯 Domain 类型，Features 只依赖本协议 + 快照（分层规则 2/3）；
/// - 业务规则（搜索/拼音分组/前 5 截断/器官回落）留在 Domain 纯函数，视图不重复实现。
public enum MedicalProfileCatalogFailure: Error, Equatable, Sendable {
    /// 切片未安装 / 不可读 / 自洽校验失败——基本需求数据缺位须显式呈现。
    case unavailable
    /// 基表数据形态非法（列缺失/JSON 坏形等）。
    case invalidData
}

public protocol MedicalProfileCatalogReading: Sendable {
    /// 一次取全量快照（13 表约 800 行，快照最简且便于代际 fencing）。
    /// `region` 先由 App 传常量 `"CN"`（manifest `regionScope` 未落回执）。
    func profileSnapshot(region: String) async throws -> MedicalProfileCatalogSnapshot
}

// MARK: - 快照模型（Sendable/Equatable；与 v3 切片 9 张读表逐字段对应）

public struct MedicalProfileCondition: Sendable, Equatable, Identifiable {
    public let catalogID: String          // condition_profile.app_catalog_id
    public let region: String
    public let officialName: String
    public let displayName: String
    public let code: String?
    public let codeSystem: String?
    public let codeVersion: String?
    /// `unverified` 时 UI 必须按「待核」呈现，不得宣称官方已核。
    public let codeStatus: String
    public let itemNature: String?
    public let bodyRegionID: String?
    public let aliases: [String]
    public var id: String { catalogID }

    public init(catalogID: String, region: String, officialName: String, displayName: String,
                code: String?, codeSystem: String?, codeVersion: String?, codeStatus: String,
                itemNature: String?, bodyRegionID: String?, aliases: [String]) {
        self.catalogID = catalogID
        self.region = region
        self.officialName = officialName
        self.displayName = displayName
        self.code = code
        self.codeSystem = codeSystem
        self.codeVersion = codeVersion
        self.codeStatus = codeStatus
        self.itemNature = itemNature
        self.bodyRegionID = bodyRegionID
        self.aliases = aliases
    }
}

public struct MedicalProfileSurgery: Sendable, Equatable, Identifiable {
    public let catalogID: String          // surgery.app_catalog_id
    public let region: String
    public let nameZh: String
    public let code: String?
    public let codeSystem: String?
    public let codeVersion: String?
    /// v3 全量 `unmapped`；手术通常无码。
    public let codeStatus: String
    public let bodyRegionID: String?
    public let aliases: [String]
    public var id: String { catalogID }

    public init(catalogID: String, region: String, nameZh: String, code: String?,
                codeSystem: String?, codeVersion: String?, codeStatus: String,
                bodyRegionID: String?, aliases: [String]) {
        self.catalogID = catalogID
        self.region = region
        self.nameZh = nameZh
        self.code = code
        self.codeSystem = codeSystem
        self.codeVersion = codeVersion
        self.codeStatus = codeStatus
        self.bodyRegionID = bodyRegionID
        self.aliases = aliases
    }
}

public struct MedicalProfileOrgan: Sendable, Equatable, Identifiable {
    public let organID: String
    public let region: String
    public let nameZh: String
    public let bodyRegionID: String
    public let sortOrder: Int64
    public var id: String { organID }

    public init(organID: String, region: String, nameZh: String,
                bodyRegionID: String, sortOrder: Int64) {
        self.organID = organID
        self.region = region
        self.nameZh = nameZh
        self.bodyRegionID = bodyRegionID
        self.sortOrder = sortOrder
    }
}

public struct MedicalProfileDepartment: Sendable, Equatable {
    public let code: String
    public let region: String
    /// 官方全称（如「心血管内科专业」）；与 facility 切片 department 同源 172 行。
    public let officialName: String
    public let categoryZh: String?

    public init(code: String, region: String, officialName: String, categoryZh: String?) {
        self.code = code
        self.region = region
        self.officialName = officialName
        self.categoryZh = categoryZh
    }
}

public struct MedicalProfileDepartmentLink: Sendable, Equatable {
    public let subjectCatalogID: String   // condition/surgery app_catalog_id
    public let departmentCode: String
    public let role: String
    public let derivation: String

    public init(subjectCatalogID: String, departmentCode: String, role: String, derivation: String) {
        self.subjectCatalogID = subjectCatalogID
        self.departmentCode = departmentCode
        self.role = role
        self.derivation = derivation
    }
}

public struct MedicalProfileOrganLink: Sendable, Equatable {
    public let subjectCatalogID: String
    public let organID: String
    public let role: String
    public let derivation: String
    public let confidence: Double?

    public init(subjectCatalogID: String, organID: String, role: String,
                derivation: String, confidence: Double?) {
        self.subjectCatalogID = subjectCatalogID
        self.organID = organID
        self.role = role
        self.derivation = derivation
        self.confidence = confidence
    }
}

public struct MedicalProfileRank: Sendable, Equatable {
    public let subjectKind: String        // condition / surgery
    public let subjectCatalogID: String
    public let region: String
    public let rank: Int64
    public let rankTotal: Int64
    public let metric: String
    /// 全量 `derived`（2024 年鉴出院量/主诊断代理）——UI 必须按
    /// 「按公开统计整理」呈现，不得宣称官方前 N。
    public let rankBasis: String
    public let value: Double?
    public let unit: String?
    public let reportYear: Int64?
    public let reportTitle: String?
    public let publisher: String?

    public init(subjectKind: String, subjectCatalogID: String, region: String,
                rank: Int64, rankTotal: Int64, metric: String, rankBasis: String,
                value: Double?, unit: String?, reportYear: Int64?,
                reportTitle: String?, publisher: String?) {
        self.subjectKind = subjectKind
        self.subjectCatalogID = subjectCatalogID
        self.region = region
        self.rank = rank
        self.rankTotal = rankTotal
        self.metric = metric
        self.rankBasis = rankBasis
        self.value = value
        self.unit = unit
        self.reportYear = reportYear
        self.reportTitle = reportTitle
        self.publisher = publisher
    }
}

public struct MedicalProfileCatalogSnapshot: Sendable, Equatable {
    public let region: String
    public let conditions: [MedicalProfileCondition]
    public let surgeries: [MedicalProfileSurgery]
    public let organs: [MedicalProfileOrgan]
    public let departments: [MedicalProfileDepartment]
    public let conditionDepartments: [MedicalProfileDepartmentLink]
    public let surgeryDepartments: [MedicalProfileDepartmentLink]
    public let conditionOrgans: [MedicalProfileOrganLink]
    public let surgeryOrgans: [MedicalProfileOrganLink]
    public let conditionRanks: [MedicalProfileRank]
    public let surgeryRanks: [MedicalProfileRank]

    public init(region: String, conditions: [MedicalProfileCondition],
                surgeries: [MedicalProfileSurgery], organs: [MedicalProfileOrgan],
                departments: [MedicalProfileDepartment],
                conditionDepartments: [MedicalProfileDepartmentLink],
                surgeryDepartments: [MedicalProfileDepartmentLink],
                conditionOrgans: [MedicalProfileOrganLink],
                surgeryOrgans: [MedicalProfileOrganLink],
                conditionRanks: [MedicalProfileRank],
                surgeryRanks: [MedicalProfileRank]) {
        self.region = region
        self.conditions = conditions
        self.surgeries = surgeries
        self.organs = organs
        self.departments = departments
        self.conditionDepartments = conditionDepartments
        self.surgeryDepartments = surgeryDepartments
        self.conditionOrgans = conditionOrgans
        self.surgeryOrgans = surgeryOrgans
        self.conditionRanks = conditionRanks
        self.surgeryRanks = surgeryRanks
    }
}
