#if os(iOS) || os(macOS)
// linux-blind: GRDB 只读池/目录匹配 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import CryptoKit
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
    /// v7 merged `drug_detail` into `drug` and trimmed `drug_reference`; the
    /// query branches on the layout declared inside the slice itself.
    private let isV7Layout: Bool
    private let isV8Layout: Bool
    private let isV9Layout: Bool

    public init(path: URL) throws {
        let observed = try Self.inspectSliceMeta(path: path)
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        let opened = try DatabasePool(path: path.path, configuration: configuration)
        self.pool = opened
        self.sliceMeta = observed
        self.isV7Layout = observed.physicalSchema == "catalog-v7"
        self.isV8Layout = observed.physicalSchema == "catalog-v8"
        self.isV9Layout = observed.physicalSchema == "catalog-v9"
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
            if self.isV9Layout {
                var exact: [MedicalCatalogDrug] = []
                if !codeValues.isEmpty {
                    let placeholders = Array(repeating: "?", count: codeValues.count).joined(separator: ",")
                    exact = try Self.v9Rows(db, sql: """
                        SELECT DISTINCT d.* FROM drug d
                        JOIN drug_sections s ON s.drug_id = d.id
                        WHERE s.kind = 'text'
                          AND s.field IN ('insurance_code', 'drug_code')
                          AND s.value IN (\(placeholders))
                        ORDER BY d.id LIMIT 20
                        """, arguments: StatementArguments(codeValues))
                }
                if !exact.isEmpty {
                    return MedicalCatalogMatching.resolve(exact: exact, candidates: [])
                }
                let name = line.printedName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    return MedicalCatalogMatch(status: .unmatched, exact: nil, candidates: [])
                }
                let like = "%" + CatalogSQLLike.escaped(name) + "%"
                var candidates = try Self.v9Rows(db, sql: """
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
        if isV9Layout {
            // v9 主库不再保存 drug_reference；参考链接入口应随契约移除。
            return []
        }
        return try await pool.read { db in
            if self.isV7Layout || self.isV8Layout {
                // v7/v8 keep only link + status; region/name/licence come from drug.
                return try Row.fetchAll(db, sql: """
                    SELECT reference_id, image_urls_json, match_status
                    FROM drug_reference WHERE drug_id = ? ORDER BY reference_id
                    """, arguments: [drug.id]).map { row in
                    MedicalCatalogReference(
                        referenceID: String(row["reference_id"] as Int64),
                        region: drug.region, sourceID: drug.sourceID,
                        licenseNo: drug.licenseNo, nameZh: drug.nameZh, nameEn: drug.nameEn,
                        brandName: drug.brandName, specificationRaw: drug.spec,
                        imageURLsJSON: row["image_urls_json"] as String? ?? "[]",
                        matchStatus: MedicalCatalogMatchStatus(rawValue: row["match_status"] as String? ?? "unmatched") ?? .unmatched)
                }
            }
            return try Row.fetchAll(db, sql: """
                SELECT reference_id, region, source_id, license_no, name_zh, name_en, brand_name,
                       spec_raw, image_urls_json, match_status
                FROM drug_reference WHERE region = ? AND source_id = ? ORDER BY reference_id
                """, arguments: [drug.region, drug.sourceID]).map(Self.reference)
        }
    }

    public func detail(for drug: MedicalCatalogDrug) async throws -> MedicalCatalogDrugDetail? {
        try await pool.read { db in
            if self.isV9Layout {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT field, value FROM drug_sections
                    WHERE drug_id = ? AND kind = 'text'
                      AND field IN ('usage_text', 'indications')
                    """, arguments: [drug.id])
                var usage: String?
                var indications: String?
                for row in rows {
                    let field: String = row["field"]
                    let value = row["value"] as String?
                    if field == "usage_text" { usage = value } else { indications = value }
                }
                return MedicalCatalogDrugDetail(
                    region: drug.region, sourceID: drug.sourceID,
                    usageText: usage, indications: indications,
                    activeIngredients: nil,
                    usageReferenceJSON: "{}", rawJSON: "{}")
            }
            if self.isV8Layout {
                let detail = try Row.fetchOne(db, sql: """
                    SELECT usage_text, indications FROM drug WHERE id = ?
                    """, arguments: [drug.id]).map { row in
                    MedicalCatalogDrugDetail(
                        region: drug.region, sourceID: drug.sourceID,
                        usageText: row["usage_text"] as String?,
                        indications: row["indications"] as String?,
                        activeIngredients: nil,
                        usageReferenceJSON: "{}", rawJSON: "{}")
                }
                let active: String? = try Row.fetchOne(db, sql: """
                    SELECT value FROM drug_sections
                    WHERE drug_id = ? AND field = 'active_ingredients' AND kind = 'text'
                    LIMIT 1
                    """, arguments: [drug.id]).flatMap { row in
                    (row["value"] as Data?).flatMap { String(data: $0, encoding: .utf8) }
                }
                guard var detail else { return nil }
                detail = MedicalCatalogDrugDetail(
                    region: detail.region, sourceID: detail.sourceID,
                    usageText: detail.usageText, indications: detail.indications,
                    activeIngredients: active,
                    usageReferenceJSON: detail.usageReferenceJSON, rawJSON: detail.rawJSON)
                return detail
            }
            if self.isV7Layout {
                return try Row.fetchOne(db, sql: """
                    SELECT usage_text, indications, active_ingredients
                    FROM drug WHERE id = ?
                    """, arguments: [drug.id]).map { row in
                    MedicalCatalogDrugDetail(
                        region: drug.region, sourceID: drug.sourceID,
                        usageText: row["usage_text"] as String?,
                        indications: row["indications"] as String?,
                        activeIngredients: row["active_ingredients"] as String?,
                        usageReferenceJSON: "{}", rawJSON: "{}")
                }
            }
            return try Row.fetchOne(db, sql: """
                SELECT region, source_id, usage_text, indications, active_ingredients,
                       usage_ref_json, raw_json
                FROM drug_detail WHERE region = ? AND source_id = ?
                """, arguments: [drug.region, drug.sourceID]).map(Self.detail)
        }
    }

    public func drug(id: Int) async throws -> MedicalCatalogDrug? {
        try await pool.read { db in
            if self.isV9Layout {
                return try Self.v9Rows(db, sql: "SELECT * FROM drug WHERE id = ?", arguments: [id]).first
            }
            return try Row.fetchOne(db, sql: "SELECT * FROM drug WHERE id = ?", arguments: [id]).map(Self.drug)
        }
    }

    // MARK: - 行映射（与 v4 同口径）

    private static func rows(_ db: Database, sql: String, arguments: StatementArguments) throws -> [MedicalCatalogDrug] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map(drug)
    }

    /// v9 moved 20 registry columns out of `drug`; the model still exposes the
    /// same shape, so load the text rows for the result ids and map them back.
    private static let v9TextFields = ["license_no", "dosage_form", "spec", "drug_category",
                                       "license_holder", "manufacturer", "insurance_code", "drug_code"]

    private static func v9Rows(_ db: Database, sql: String,
                               arguments: StatementArguments) throws -> [MedicalCatalogDrug] {
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        let ids = rows.map { $0["id"] as Int }
        guard !ids.isEmpty else { return [] }
        let idPlaceholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        // Field names are code constants (not user input); binding only ids
        // keeps StatementArguments homogeneous.
        let fieldList = v9TextFields.map { "'\($0)'" }.joined(separator: ",")
        let fieldRows = try Row.fetchAll(db, sql: """
            SELECT drug_id, field, value FROM drug_sections
            WHERE kind = 'text' AND drug_id IN (\(idPlaceholders))
              AND field IN (\(fieldList))
            """, arguments: StatementArguments(ids))
        var text: [Int: [String: String]] = [:]
        for row in fieldRows {
            guard let value = row["value"] as String? else { continue }
            text[row["drug_id"] as Int, default: [:]][row["field"] as String] = value
        }
        return rows.map { drug($0, text: text[$0["id"] as Int] ?? [:]) }
    }

    private static func drug(_ row: Row, text: [String: String]) -> MedicalCatalogDrug {
        MedicalCatalogDrug(
            id: row["id"], region: row["region"], sourceID: row["source_id"],
            licenseNo: text["license_no"],
            nameZh: row["name_zh"], nameEn: row["name_en"], brandName: row["brand_name"],
            dosageForm: text["dosage_form"], spec: text["spec"], drugCategory: text["drug_category"],
            licenseHolder: text["license_holder"], manufacturer: text["manufacturer"],
            insuranceCode: text["insurance_code"], drugCode: text["drug_code"],
            activeIngredients: nil, usageReferenceJSON: "{}")
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

    // MARK: - 说明书（v7；正文压缩一份，章节只存位置）

    public func documentSources(forDrugID drugID: Int) async throws -> [MedicalCatalogDrugDocument] {
        if isV8Layout {
            return try await pool.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT source_id, field, kind, value, content_sha256
                    FROM drug_sections
                    WHERE drug_id = ? AND field IN ('document','source_url','fetched_at','match_verified')
                    ORDER BY source_id
                    """, arguments: [drugID])
                var bySource: [String: (hash: Data?, url: String?, at: String?, verified: Bool)] = [:]
                for row in rows {
                    let sourceID: String = row["source_id"]
                    let field: String = row["field"]
                    var slot = bySource[sourceID] ?? (nil, nil, nil, false)
                    switch field {
                    case "document":
                        slot.hash = row["content_sha256"] as Data?
                    case "source_url":
                        slot.url = (row["value"] as Data?).flatMap { String(data: $0, encoding: .utf8) }
                    case "fetched_at":
                        slot.at = (row["value"] as Data?).flatMap { String(data: $0, encoding: .utf8) }
                    case "match_verified":
                        slot.verified = ((row["value"] as Data?).flatMap { String(data: $0, encoding: .utf8) }) == "1"
                    default: break
                    }
                    bySource[sourceID] = slot
                }
                var name = ""
                var maker = ""
                if let drug = try Row.fetchOne(db, sql: "SELECT name_zh, manufacturer FROM drug WHERE id = ?",
                                               arguments: [drugID]) {
                    name = drug["name_zh"] ?? ""
                    maker = drug["manufacturer"] ?? ""
                }
                return bySource.compactMap { sourceID, slot -> MedicalCatalogDrugDocument? in
                    guard let hash = slot.hash else { return nil }
                    return MedicalCatalogDrugDocument(
                        sourceID: sourceID, docSHA256: hash,
                        nameZh: name, manufacturer: maker,
                        matchMethod: slot.verified ? "license_no" : "name",
                        matchVerified: slot.verified,
                        sourceURL: slot.url ?? "", fetchedAt: slot.at ?? "")
                }.sorted { lhs, rhs in
                    if lhs.matchVerified != rhs.matchVerified { return lhs.matchVerified }
                    return lhs.fetchedAt > rhs.fetchedAt
                }
            }
        }
        if isV9Layout {
            return try await pool.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT name_zh,
                           (SELECT value FROM drug_sections
                            WHERE drug_id = drug.id AND kind = 'text'
                              AND field = 'manufacturer' LIMIT 1) AS manufacturer,
                           document_source_id, document_sha256,
                           document_source_url, document_fetched_at, document_match_verified
                    FROM drug WHERE id = ? AND document_sha256 IS NOT NULL
                    """, arguments: [drugID]),
                      let hash = row["document_sha256"] as Data? else { return [] }
                let verified = (row["document_match_verified"] as Int64? ?? 0) == 1
                return [MedicalCatalogDrugDocument(
                    sourceID: (row["document_source_id"] as String?) ?? "39net",
                    docSHA256: hash,
                    nameZh: (row["name_zh"] as String?) ?? "",
                    manufacturer: (row["manufacturer"] as String?) ?? "",
                    matchMethod: verified ? "license_no" : "name",
                    matchVerified: verified,
                    sourceURL: (row["document_source_url"] as String?) ?? "",
                    fetchedAt: (row["document_fetched_at"] as String?) ?? "")]
            }
        }
        guard isV7Layout else { return [] }
        return try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.source_id, s.doc_sha256, s.name_zh, s.manufacturer,
                       s.source_url, s.fetched_at, l.match_method, l.match_verified
                FROM leaflet_link l JOIN leaflet_source s ON s.source_id = l.source_id
                WHERE l.drug_id = ?
                ORDER BY l.match_verified DESC, s.fetched_at DESC
                """, arguments: [drugID]).map { row in
                MedicalCatalogDrugDocument(
                    sourceID: row["source_id"], docSHA256: row["doc_sha256"],
                    nameZh: row["name_zh"], manufacturer: row["manufacturer"],
                    matchMethod: row["match_method"],
                    matchVerified: (row["match_verified"] as Int64) == 1,
                    sourceURL: row["source_url"], fetchedAt: row["fetched_at"])
            }
        }
    }

    public func documentSections(docSHA256: Data) async throws -> [MedicalCatalogDrugSection] {
        if isV9Layout {
            return try await pool.read { db in
                let sections = try Row.fetchAll(db, sql: """
                    SELECT field, ordinal, value FROM drug_sections
                    WHERE kind = 'span'
                      AND drug_id = (SELECT id FROM drug WHERE document_sha256 = ? LIMIT 1)
                    """, arguments: [docSHA256]).compactMap { row -> MedicalCatalogDrugSection? in
                    guard let value = row["value"] as Data?, value.count == 8 else { return nil }
                    let start = value.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
                    let end = value.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
                    return MedicalCatalogDrugSection(ordinal: row["ordinal"], kind: row["field"],
                                                        charStart: Int(UInt32(littleEndian: start)),
                                                        charEnd: Int(UInt32(littleEndian: end)))
                }
                return sections.sorted { lhs, rhs in
                    if lhs.charStart != rhs.charStart { return lhs.charStart < rhs.charStart }
                    if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
                    return lhs.ordinal < rhs.ordinal
                }
            }
        }
        if isV8Layout {
            return try await pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT field, ordinal, value FROM drug_sections
                    WHERE content_sha256 = ? AND kind = 'span'
                    GROUP BY field, ordinal ORDER BY ordinal
                    """, arguments: [docSHA256]).compactMap { row in
                    guard let value = row["value"] as Data?, value.count == 8 else { return nil }
                    let start = value.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
                    let end = value.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
                    return MedicalCatalogDrugSection(ordinal: row["ordinal"], kind: row["field"],
                                                        charStart: Int(UInt32(littleEndian: start)),
                                                        charEnd: Int(UInt32(littleEndian: end)))
                }
            }
        }
        guard isV7Layout else { return [] }
        return try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ordinal, kind, char_start, char_end FROM leaflet_section
                WHERE doc_sha256 = ? ORDER BY ordinal
                """, arguments: [docSHA256]).map { row in
                MedicalCatalogDrugSection(ordinal: row["ordinal"], kind: row["kind"],
                                             charStart: row["char_start"], charEnd: row["char_end"])
            }
        }
    }

    /// 解压整份说明书；损坏时报错，不返回空串冒充「没有内容」。
    public func documentText(docSHA256: Data) async throws -> String {
        if isV9Layout {
            let payload: (Data, Int)? = try await pool.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT document_zlib, document_text_bytes FROM drug
                    WHERE document_sha256 = ? AND document_zlib IS NOT NULL LIMIT 1
                    """, arguments: [docSHA256]),
                      let compressed = row["document_zlib"] as Data?,
                      let expected = row["document_text_bytes"] as Int? else { return nil }
                return (compressed, expected)
            }
            guard let (compressed, expected) = payload else { throw CatalogSliceDrugSectionsFailure.unavailable }
            guard let decoded = CatalogSliceDrugSectionsCodec.inflate(compressed),
                  decoded.utf8.count == expected,
                  Data(SHA256.hash(data: Data(decoded.utf8))) == docSHA256 else {
                throw CatalogSliceDrugSectionsFailure.corruptText
            }
            return decoded
        }
        if isV8Layout {
            let payload: (Data, Int)? = try await pool.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT value, text_bytes FROM drug_sections
                    WHERE content_sha256 = ? AND kind = 'zlib' LIMIT 1
                    """, arguments: [docSHA256]),
                      let compressed = row["value"] as Data?,
                      let expected = row["text_bytes"] as Int? else { return nil }
                return (compressed, expected)
            }
            guard let (compressed, expected) = payload else { throw CatalogSliceDrugSectionsFailure.unavailable }
            guard let decoded = CatalogSliceDrugSectionsCodec.inflate(compressed),
                  decoded.utf8.count == expected,
                  Data(SHA256.hash(data: Data(decoded.utf8))) == docSHA256 else {
                throw CatalogSliceDrugSectionsFailure.corruptText
            }
            return decoded
        }
        guard isV7Layout else { throw CatalogSliceDrugSectionsFailure.legacySchema }
        let payload: (Data, Int)? = try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT text_zlib, text_bytes FROM leaflet_doc WHERE doc_sha256 = ?",
                             arguments: [docSHA256]).map { ($0["text_zlib"] as Data, $0["text_bytes"] as Int) }
        }
        guard let (compressed, expected) = payload else { throw CatalogSliceDrugSectionsFailure.unavailable }
        guard let decoded = CatalogSliceDrugSectionsCodec.inflate(compressed), decoded.utf8.count == expected else {
            throw CatalogSliceDrugSectionsFailure.corruptText
        }
        return decoded
    }

    /// 一节正文；偏移是 Unicode 码点（与解析器一致），不是 UTF-8 字节。
    public func sectionText(_ section: MedicalCatalogDrugSection, in text: String) -> String? {
        // 偏移是 Unicode 码点；`Array(text)` 是字素簇，遇到 CRLF/组合字符会错位。
        let scalars = text.unicodeScalars
        guard section.charStart >= 0, section.charEnd > section.charStart,
              let start = scalars.index(scalars.startIndex, offsetBy: section.charStart,
                                        limitedBy: scalars.endIndex),
              let end = scalars.index(start, offsetBy: section.charEnd - section.charStart,
                                      limitedBy: scalars.endIndex) else { return nil }
        return String(scalars[start..<end])
    }
}
#endif
