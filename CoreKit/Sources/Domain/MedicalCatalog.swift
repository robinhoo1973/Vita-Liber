import Foundation

/// 独立药品目录的只读事实模型；不写入用户主库，也不自动生成 medication_id。
public struct MedicalCatalogDrug: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let region: String
    public let sourceID: String
    public let licenseNo: String?
    public let nameZh: String?
    public let nameEn: String?
    public let brandName: String?
    public let dosageForm: String?
    public let spec: String?
    public let drugCategory: String?
    public let licenseHolder: String?
    public let manufacturer: String?
    public let insuranceCode: String?
    public let drugCode: String?
    public let activeIngredients: String?
    public let usageReferenceJSON: String

    public var displayName: String {
        nameZh?.isEmpty == false ? nameZh! : (nameEn ?? brandName ?? sourceID)
    }

    public init(id: Int, region: String, sourceID: String, licenseNo: String?, nameZh: String?,
                nameEn: String?, brandName: String?, dosageForm: String?, spec: String?,
                drugCategory: String?, licenseHolder: String?, manufacturer: String?,
                insuranceCode: String?, drugCode: String?, activeIngredients: String?,
                usageReferenceJSON: String) {
        self.id = id; self.region = region; self.sourceID = sourceID; self.licenseNo = licenseNo
        self.nameZh = nameZh; self.nameEn = nameEn; self.brandName = brandName; self.dosageForm = dosageForm
        self.spec = spec; self.drugCategory = drugCategory; self.licenseHolder = licenseHolder
        self.manufacturer = manufacturer; self.insuranceCode = insuranceCode; self.drugCode = drugCode
        self.activeIngredients = activeIngredients; self.usageReferenceJSON = usageReferenceJSON
    }
}

public enum MedicalCatalogMatchStatus: String, Codable, Sendable {
    case exact
    case candidate
    case conflict
    case unmatched
}

public struct MedicalCatalogMatch: Sendable, Equatable {
    public let status: MedicalCatalogMatchStatus
    public let exact: MedicalCatalogDrug?
    public let candidates: [MedicalCatalogDrug]

    public init(status: MedicalCatalogMatchStatus, exact: MedicalCatalogDrug?, candidates: [MedicalCatalogDrug]) {
        self.status = status; self.exact = exact; self.candidates = candidates
    }
}

/// Exact-first resolution shared by the SQLite adapter and its test contract.
/// A candidate or conflict is evidence only; no result selects a medication_id.
public enum MedicalCatalogMatching {
    public static func resolve(exact: [MedicalCatalogDrug], candidates: [MedicalCatalogDrug]) -> MedicalCatalogMatch {
        if exact.count == 1 {
            return MedicalCatalogMatch(status: .exact, exact: exact[0], candidates: exact)
        }
        if exact.count > 1 {
            return MedicalCatalogMatch(status: .conflict, exact: nil, candidates: exact)
        }
        if candidates.count == 1 {
            return MedicalCatalogMatch(status: .candidate, exact: nil, candidates: candidates)
        }
        if candidates.count > 1 {
            return MedicalCatalogMatch(status: .conflict, exact: nil, candidates: candidates)
        }
        return MedicalCatalogMatch(status: .unmatched, exact: nil, candidates: [])
    }
}

public struct MedicalCatalogReference: Sendable, Equatable {
    public let referenceID: String
    public let region: String
    public let sourceID: String
    public let licenseNo: String?
    public let nameZh: String?
    public let nameEn: String?
    public let brandName: String?
    public let specificationRaw: String?
    public let imageURLsJSON: String
    public let matchStatus: MedicalCatalogMatchStatus

    public init(referenceID: String, region: String, sourceID: String, licenseNo: String?, nameZh: String?,
                nameEn: String?, brandName: String?, specificationRaw: String?, imageURLsJSON: String,
                matchStatus: MedicalCatalogMatchStatus) {
        self.referenceID = referenceID; self.region = region; self.sourceID = sourceID; self.licenseNo = licenseNo
        self.nameZh = nameZh; self.nameEn = nameEn; self.brandName = brandName
        self.specificationRaw = specificationRaw; self.imageURLsJSON = imageURLsJSON; self.matchStatus = matchStatus
    }
}

public struct MedicalCatalogDrugDetail: Sendable, Equatable {
    public let region: String
    public let sourceID: String
    public let usageText: String?
    public let indications: String?
    public let activeIngredients: String?
    public let usageReferenceJSON: String
    public let rawJSON: String

    public init(region: String, sourceID: String, usageText: String?, indications: String?,
                activeIngredients: String?, usageReferenceJSON: String, rawJSON: String) {
        self.region = region
        self.sourceID = sourceID
        self.usageText = usageText
        self.indications = indications
        self.activeIngredients = activeIngredients
        self.usageReferenceJSON = usageReferenceJSON
        self.rawJSON = rawJSON
    }
}

/// 独立 catalog 的读取端口。更新/解密服务通过基础设施实现，不让 App 视图接触文件与 SQL。
public protocol MedicalCatalogReading: Sendable {
    func match(line: PrescriptionLine) async throws -> MedicalCatalogMatch
    func reference(for drug: MedicalCatalogDrug) async throws -> [MedicalCatalogReference]
    func detail(for drug: MedicalCatalogDrug) async throws -> MedicalCatalogDrugDetail?
}
