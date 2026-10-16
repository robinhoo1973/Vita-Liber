#if os(iOS) || os(macOS)
// linux-blind: GRDB 存储契约仅 Apple 平台链接（Package.swift ERR#8 纪律），Linux 编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB

/// The public producer contract is bundled verbatim. Opening a snapshot checks its
/// shape and current identity, not its multi-GB logical digest (the release gate's job).
enum MedicalCatalogStorageContract {
    static let marker = "unified-medical-kg/v1"
    static let physicalSchema = 9

    private struct Contract: Decodable {
        let storageContract: String
        let physicalSchema: Int
        let graphSchema: Int
        let appCatalogSchema: Int
        let appColumns: [String: [String]]
        let requiredGraphColumns: [String: [String]]
        let requiredViews: [String]

        enum CodingKeys: String, CodingKey {
            case storageContract = "storage_contract"
            case physicalSchema = "physical_schema"
            case graphSchema = "graph_schema"
            case appCatalogSchema = "app_catalog_schema"
            case appColumns = "app_columns"
            case requiredGraphColumns = "required_graph_columns"
            case requiredViews = "required_views"
        }
    }

    private static func contract() throws -> Contract {
        guard let url = Bundle.module.url(forResource: "unified-contract-v1",
                                          withExtension: "json", subdirectory: "Resources") else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        let definition = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
        guard definition.storageContract == marker, definition.physicalSchema == physicalSchema,
              definition.graphSchema == 2, definition.appCatalogSchema == 4 else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        return definition
    }

    static func values(_ db: Database, table: String) throws -> [String: String] {
        guard try Row.fetchOne(db, sql:
            "SELECT 1 FROM \"\(table)\" WHERE typeof(key)!='text' OR typeof(value)!='text' LIMIT 1") == nil else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        var result: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key, value FROM \"\(table)\"") {
            let key: String = row["key"]
            let value: String = row["value"]
            guard result.updateValue(value, forKey: key) == nil else {
                throw MedicalCatalogUpdateError.catalogIntegrityFailed
            }
        }
        return result
    }

    static func inspect(_ db: Database, schemaVersion: Int? = nil,
                        dataVersion: String? = nil, contentSHA256: String? = nil) throws -> MedicalCatalogInstalledVersion {
        guard try String.fetchOne(db, sql:
            "SELECT type FROM sqlite_schema WHERE name = 'catalog_meta'") == "table" else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        let meta = try values(db, table: "catalog_meta")
        guard let schemaText = meta["schema_version"], let schema = Int(schemaText),
              String(schema) == schemaText,
              MedicalCatalogReleaseProtocol.supportedSQLiteSchemaVersions.contains(schema),
              try Int.fetchOne(db, sql: "PRAGMA user_version") == schema,
              let data = meta["data_version"], !data.isEmpty,
              schemaVersion == nil || schemaVersion == schema,
              dataVersion == nil || dataVersion == data else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        let metadataType = try String.fetchOne(db, sql:
            "SELECT type FROM sqlite_schema WHERE name = 'metadata'")
        guard metadataType == nil || metadataType == "table" else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        let graph = metadataType != nil ? try values(db, table: "metadata") : [:]
        let hasMarker = meta["storage_contract"] != nil || graph["storage_contract"] != nil
        if schema != physicalSchema {
            guard !hasMarker, graph["schema_version"] != "2" else {
                throw MedicalCatalogUpdateError.catalogIntegrityFailed
            }
            return MedicalCatalogInstalledVersion(schemaVersion: schema, dataVersion: data)
        }
        guard meta["storage_contract"] == marker,
              meta["app_catalog_schema_version"] == "4",
              meta["graph_schema_version"] == "2",
              meta["catalog_ready"] == "true", meta["content_scope"] == "full",
              graph["format"] == "vita_liber_evidence_graph",
              graph["schema_version"] == "2",
              graph["lifecycle"] == "versioned",
              graph["storage_contract"] == nil || graph["storage_contract"] == marker,
              graph["release_id"] == data,
              MedicalCatalogReleaseProtocol.isLowercaseSHA256(data),
              contentSHA256 == nil || contentSHA256 == data,
              let activationID = graph["activation_id"], !activationID.isEmpty else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        let definition = try contract()
        for (name, expected) in definition.appColumns {
            try checkTable(db, name: name, columns: expected, exact: true)
        }
        for (name, expected) in definition.requiredGraphColumns {
            try checkTable(db, name: name, columns: expected, exact: false)
        }
        for name in definition.requiredViews {
            guard try String.fetchOne(db, sql:
                "SELECT name FROM sqlite_schema WHERE type = 'view' AND name = ?", arguments: [name]) != nil else {
                throw MedicalCatalogUpdateError.catalogIntegrityFailed
            }
            _ = try Row.fetchAll(db, sql: "SELECT * FROM \"\(name)\" LIMIT 0")
        }
        for (table, key) in [
            ("catalog_meta", ["key"]), ("metadata", ["key"]), ("drug", ["id"]),
            ("drug_reference", ["reference_id"]), ("drug_detail", ["region", "source_id"]),
            ("graph_release", ["release_id"]), ("graph_activation", ["activation_id"]),
            ("catalog_entry", ["entry_uid"]), ("catalog_revision", ["revision_uid"]),
            ("assertion_review", ["review_uid"]), ("current_assertion_review", ["assertion_uid"]),
            ("producer_import", ["input_sha256"]),
            ("catalog_history", ["activation_id", "entry_uid"]),
            ("source_record_history", ["activation_id", "record_uid"]),
            ("assertion_history", ["activation_id", "assertion_uid"])
        ] {
            try checkPrimaryKey(db, table: table, columns: key)
        }
        for table in ["drug", "hospital", "department", "diagnosis", "exam_item"] {
            let keys = try uniqueKeys(db, table: table)
            guard keys.contains(["region", "source_id"]), !keys.contains(["source_id"]) else {
                throw MedicalCatalogUpdateError.catalogIntegrityFailed
            }
        }
        guard try uniqueKeys(db, table: "graph_activation").contains(["sequence"]),
              try uniqueKeys(db, table: "catalog_entry").contains(["table_name", "app_row_id"]),
              try uniqueKeys(db, table: "catalog_entry").contains(["table_name", "record_id"]) else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        guard let input = meta["producer_input_sha256"],
              MedicalCatalogReleaseProtocol.isLowercaseSHA256(input),
              let producerVersion = meta["producer_data_version"], !producerVersion.isEmpty,
              try Row.fetchOne(db, sql: """
                SELECT 1 FROM producer_import
                WHERE input_sha256=? AND producer_data_version=? AND json_valid(metadata_json)
                """, arguments: [input, producerVersion]) != nil else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        guard let release = try Row.fetchOne(db, sql: """
            SELECT content_sha256, status, scope, catalog_count, entity_count, assertion_count,
                   json_valid(source_manifest_json) AS valid_manifest
            FROM graph_release WHERE release_id = ?
            """, arguments: [data]),
              release["content_sha256"] as String == data,
              release["status"] as String == "validated",
              release["scope"] as String == "full",
              release["catalog_count"] as Int64 > 0,
              release["entity_count"] as Int64 >= 0,
              release["assertion_count"] as Int64 >= 0,
              release["valid_manifest"] as Int == 1,
              try String.fetchOne(db, sql: """
                SELECT release_id FROM graph_activation
                WHERE activation_id = ? AND typeof(sequence) = 'integer' AND sequence > 0
                """, arguments: [activationID]) == data else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        try checkCurrentBindings(db, definition: definition, count: release["catalog_count"])
        try checkCurrentReview(db)
        for table in ["catalog_history", "source_record_history", "assertion_history"] {
            guard try Row.fetchOne(db, sql:
                "SELECT 1 FROM \(table) WHERE activation_id=? AND release_id IS NOT ? LIMIT 1",
                arguments: [activationID, data]) == nil else {
                throw MedicalCatalogUpdateError.catalogIntegrityFailed
            }
        }
        return MedicalCatalogInstalledVersion(schemaVersion: schema, dataVersion: data,
                                              contentSHA256: data, activationID: activationID)
    }

    private static func checkCurrentReview(_ db: Database) throws {
        guard try Row.fetchOne(db, sql: """
            SELECT 1 FROM active_assertion a
            LEFT JOIN current_assertion_review c ON c.assertion_uid=a.uid
            LEFT JOIN assertion_review r ON r.review_uid=c.review_uid
            WHERE (a.review_status='approved' AND c.review_uid IS NULL)
               OR (c.review_uid IS NOT NULL AND (
                    r.review_uid IS NULL OR r.assertion_uid IS NOT a.uid OR r.status IS NOT a.review_status
                    OR coalesce(length(trim(r.actor)),0)=0 OR coalesce(length(trim(r.rationale)),0)=0))
            LIMIT 1
            """) == nil else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
    }

    private static func checkPrimaryKey(_ db: Database, table: String, columns: [String]) throws {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
        let key = rows.filter { ($0["pk"] as Int) > 0 }
            .sorted { ($0["pk"] as Int) < ($1["pk"] as Int) }
            .map { (row: Row) -> String in row["name"] }
        guard key == columns else { throw MedicalCatalogUpdateError.catalogIntegrityFailed }
    }

    private static func uniqueKeys(_ db: Database, table: String) throws -> [[String]] {
        try Row.fetchAll(db, sql: "PRAGMA index_list(\"\(table)\")")
            .filter { ($0["unique"] as Int) == 1 && ($0["partial"] as Int) == 0 }
            .map { row in
                let name: String = row["name"]
                let quoted = name.replacingOccurrences(of: "\"", with: "\"\"")
                let columns = try Row.fetchAll(db, sql: "PRAGMA index_info(\"\(quoted)\")")
                    .map { (column: Row) -> String? in column["name"] }
                guard columns.allSatisfy({ $0 != nil }) else { return [] }
                return columns.compactMap { $0 }
            }
    }

    /// Only current bindings are inspected. A reused historical revision is valid
    /// provided it belongs to this entry; revision timestamps are not identities.
    private static func checkCurrentBindings(_ db: Database, definition: Contract, count: Int64) throws {
        var total: Int64 = 0
        for table in definition.appColumns.keys.sorted() where table != "catalog_meta" {
            for column in definition.appColumns[table, default: []] where column.hasSuffix("_json") {
                guard try Row.fetchOne(db, sql:
                    "SELECT 1 FROM \"\(table)\" WHERE NOT json_valid(\"\(column)\") LIMIT 1") == nil else {
                    throw MedicalCatalogUpdateError.catalogIntegrityFailed
                }
            }
            let rows = try Int64.fetchOne(db, sql: "SELECT count(*) FROM \"\(table)\"") ?? 0
            let bound = try Int64.fetchOne(db, sql:
                "SELECT count(*) FROM catalog_entry WHERE table_name = ? AND active = 1",
                arguments: [table]) ?? 0
            let recordCheck = table == "drug_reference"
                ? "json_array_length(c.record_id) != 1 OR json_extract(c.record_id, '$[0]') IS NOT t.reference_id"
                : "json_array_length(c.record_id) != 2 OR json_extract(c.record_id, '$[0]') IS NOT t.region OR json_extract(c.record_id, '$[1]') IS NOT t.source_id"
            guard rows == bound,
                  try Row.fetchOne(db, sql: """
                    SELECT 1 FROM "\(table)" t
                    LEFT JOIN catalog_entry c ON c.table_name = ? AND c.app_row_id = t.rowid AND c.active = 1
                    LEFT JOIN catalog_revision r ON r.revision_uid = c.current_revision_uid
                    LEFT JOIN entity e ON e.uid = c.entity_uid
                    LEFT JOIN entity_state s ON s.entity_uid = e.uid
                    WHERE c.entry_uid IS NULL OR c.region IS NOT t.region OR c.source_id IS NOT t.source_id
                       OR NOT json_valid(c.record_id) OR \(recordCheck)
                       OR r.revision_uid IS NULL OR r.entry_uid IS NOT c.entry_uid
                       OR e.uid IS NULL OR e.region IS NOT t.region OR coalesce(s.active, 1) != 1
                    LIMIT 1
                    """, arguments: [table]) == nil else {
                throw MedicalCatalogUpdateError.catalogIntegrityFailed
            }
            total += rows
        }
        guard total == count,
              try Int64.fetchOne(db, sql: "SELECT count(*) FROM catalog_entry WHERE active = 1") == total else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
    }

    private static func checkTable(_ db: Database, name: String,
                                   columns: [String], exact: Bool) throws {
        guard try String.fetchOne(db, sql:
            "SELECT name FROM sqlite_schema WHERE type = 'table' AND name = ?", arguments: [name]) != nil else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        let actual = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(name)\")")
            .map { (row: Row) -> String in row["name"] }
        guard exact ? actual == columns : Set(columns).isSubset(of: Set(actual)) else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
    }

    static func validate(path: URL, schemaVersion: Int, dataVersion: String,
                         contentSHA256: String? = nil, sqliteSHA256: String? = nil, smoke: Bool = true) throws {
        _ = try MedicalCatalogUpdateService.fileSize(of: path)
        if let sqliteSHA256 {
            guard try StreamingFileHasher.sha256(of: path) == sqliteSHA256 else {
                throw MedicalCatalogUpdateError.checksumMismatch
            }
        }
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() } // try?-ok: read-only handle cleanup
        guard try handle.read(upToCount: 16) == Data("SQLite format 3\u{0}".utf8) else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        var configuration = Configuration()
        configuration.readonly = true
        try DatabaseQueue(path: path.path, configuration: configuration).read { db in
            guard try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"],
                  try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil else {
                throw MedicalCatalogUpdateError.catalogIntegrityFailed
            }
            if schemaVersion == physicalSchema {
                guard try String.fetchOne(db, sql: "PRAGMA journal_mode") == "delete" else {
                    throw MedicalCatalogUpdateError.catalogIntegrityFailed
                }
            }
            _ = try inspect(db, schemaVersion: schemaVersion, dataVersion: dataVersion,
                            contentSHA256: contentSHA256)
            if smoke {
                try smokeQueries(db, schema: schemaVersion)
            }
        }
    }

    static func smokeQueries(_ db: Database, schema: Int) throws {
        let definition = try contract()
        for (table, columns) in definition.appColumns where table != "catalog_meta" {
            if table == "diagnosis", schema < 7,
               try String.fetchOne(db, sql:
                "SELECT name FROM sqlite_schema WHERE type='table' AND name='diagnosis'") == nil {
                continue
            }
            let projection = columns.map { "\"\($0)\"" }.joined(separator: ",")
            _ = try Row.fetchAll(db, sql: "SELECT \(projection) FROM \"\(table)\" LIMIT 0")
        }
    }
}
#endif
