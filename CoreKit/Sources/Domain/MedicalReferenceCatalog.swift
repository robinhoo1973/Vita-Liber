import Foundation

/// 四域参考数据（医院/科室/疾病/检查化验）的只读事实模型（独立 catalog schema v4）。
///
/// 与药品目录同纪律（BR-003/004）：不写入用户主库、不自动落任何业务字段；
/// UI 仅以 B 级「目录参考」徽章展示，用户确认后才成为 C 级事实。实体为纯值类型，
/// SQL/文件细节由 Infrastructure 的 `MedicalReferenceCatalogStore` 承接。
///
/// 新文件扩展（业主 2026-09-24 裁定）：与在途 `MedicalCatalog.swift`（药品域）互不修改。

// MARK: - 医院

public struct MedicalCatalogDepartmentRef: Codable, Sendable, Equatable {
    public let code: String?
    public let nameZh: String

    public init(code: String?, nameZh: String) {
        self.code = code
        self.nameZh = nameZh
    }
}

public struct MedicalCatalogHospital: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let region: String
    public let sourceID: String
    public let code: String?
    public let nameZh: String
    public let shortName: String?
    public let typeZh: String?
    public let levelZh: String?
    public let address: String?
    public let phone: String?
    public let adminArea: String?
    public let deptsJSON: String
    public let aliasesJSON: String
    public let contractEnd: String?

    public var aliases: [String] { CatalogJSON.stringArray(aliasesJSON) }
    public var departments: [MedicalCatalogDepartmentRef] {
        guard let data = deptsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([MedicalCatalogDepartmentRef].self, from: data) else { return [] } // try?-ok: 目录行内 depts_json 解码失败=空科室表（降级不崩）
        return list
    }

    public init(id: Int, region: String, sourceID: String, code: String?, nameZh: String, shortName: String?,
                typeZh: String?, levelZh: String?, address: String?, phone: String?, adminArea: String?,
                deptsJSON: String, aliasesJSON: String, contractEnd: String?) {
        self.id = id; self.region = region; self.sourceID = sourceID; self.code = code; self.nameZh = nameZh
        self.shortName = shortName; self.typeZh = typeZh; self.levelZh = levelZh; self.address = address
        self.phone = phone; self.adminArea = adminArea; self.deptsJSON = deptsJSON; self.aliasesJSON = aliasesJSON
        self.contractEnd = contractEnd
    }
}

// MARK: - 科室

public struct MedicalCatalogDepartment: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let region: String
    public let sourceID: String
    public let code: String
    public let nameZh: String
    public let categoryZh: String?
    public let aliasesJSON: String

    public var aliases: [String] { CatalogJSON.stringArray(aliasesJSON) }

    public init(id: Int, region: String, sourceID: String, code: String, nameZh: String,
                categoryZh: String?, aliasesJSON: String) {
        self.id = id; self.region = region; self.sourceID = sourceID; self.code = code; self.nameZh = nameZh
        self.categoryZh = categoryZh; self.aliasesJSON = aliasesJSON
    }
}

// MARK: - 疾病

public struct MedicalCatalogDiagnosis: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let region: String
    public let sourceID: String
    public let code: String
    public let nameZh: String
    public let codeSystem: String
    public let chapterZh: String?
    public let aliasesJSON: String

    public var aliases: [String] { CatalogJSON.stringArray(aliasesJSON) }

    public init(id: Int, region: String, sourceID: String, code: String, nameZh: String,
                codeSystem: String, chapterZh: String?, aliasesJSON: String) {
        self.id = id; self.region = region; self.sourceID = sourceID; self.code = code; self.nameZh = nameZh
        self.codeSystem = codeSystem; self.chapterZh = chapterZh; self.aliasesJSON = aliasesJSON
    }
}

// MARK: - 检查/化验

public struct MedicalCatalogExamItem: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let region: String
    public let sourceID: String
    public let code: String
    public let nameZh: String
    public let nameEn: String?
    public let category: String?
    public let method: String?
    public let specimen: String?
    public let unit: String?
    public let priceRef: String?
    public let loincConceptID: String?
    public let aliasesJSON: String

    public var aliases: [String] { CatalogJSON.stringArray(aliasesJSON) }

    public init(id: Int, region: String, sourceID: String, code: String, nameZh: String, nameEn: String?,
                category: String?, method: String?, specimen: String?, unit: String?, priceRef: String?,
                loincConceptID: String?, aliasesJSON: String) {
        self.id = id; self.region = region; self.sourceID = sourceID; self.code = code; self.nameZh = nameZh
        self.nameEn = nameEn; self.category = category; self.method = method; self.specimen = specimen
        self.unit = unit; self.priceRef = priceRef; self.loincConceptID = loincConceptID; self.aliasesJSON = aliasesJSON
    }
}

// MARK: - 读取端口

/// 四域参考目录的读取端口。实现位于 Infrastructure（`MedicalReferenceCatalogStore`），
/// 视图只依赖协议；catalog 文件缺四域表（schema < 4）时各方法降级返回空，不抛错。
public protocol MedicalReferenceCatalogReading: Sendable {
    func hospitalSuggest(query: String, region: String?, limit: Int) async throws -> [MedicalCatalogHospital]
    func departmentList(region: String?) async throws -> [MedicalCatalogDepartment]
    func diagnosisSuggest(query: String, system: String?, region: String?, limit: Int) async throws -> [MedicalCatalogDiagnosis]
    func examSuggest(query: String, category: String?, region: String?, limit: Int) async throws -> [MedicalCatalogExamItem]
    var catalogSchemaVersion: Int { get async throws }
}

// MARK: - 术语覆盖层

/// 四域术语覆盖层：静态 `TerminologyStore`（FR12.4 P0 内置词典）兜底解释，
/// catalog 下载后由 App 侧把四域别名→正名映射注入内存（不落患者库、零迁移）。
/// 查询链：目录别名解析成正名 → 解释优先命中原词、其次正名。
public actor MedicalTerminologyOverlay {
    public static let shared = MedicalTerminologyOverlay()

    private var catalogNames: [String: String] = [:]

    /// App 侧在 catalog 就绪后注入别名→正名映射（含正名自身→正名）。
    public func install(names: [String: String]) {
        catalogNames = names
    }

    /// 目录解析：别名→正名；目录未含该词时原样返回。
    public func canonicalName(for term: String) -> String {
        catalogNames[term] ?? term
    }

    /// 解释：原词优先，其次其正名；均无则 nil。
    public func explain(_ term: String) -> String? {
        if let direct = TerminologyStore.shared.explain(term) { return direct }
        return TerminologyStore.shared.explain(canonicalName(for: term))
    }
}

// MARK: - 内助

/// JSON 数组字符串（aliases_json/depts_json 形态）的解码内助，纯 Foundation。
enum CatalogJSON {
    static func stringArray(_ json: String) -> [String] {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] } // try?-ok: 目录行内别名 JSON 解码失败=空别名（降级不崩）
        return list
    }
}
