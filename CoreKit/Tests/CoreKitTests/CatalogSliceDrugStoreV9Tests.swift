#if os(iOS) || os(macOS)
import Domain
import Foundation
import GRDB
import Testing
@testable import Infrastructure

/// catalog-v9：20 个登记字段已移入 `drug_sections(kind='text')`，行映射必须
/// 从 text 行恢复 `MedicalCatalogDrug` 的字段，而不是读已删除的 drug 列。
@Suite("SU-M2-CATALOG · catalog-v9 药品行映射")
struct CatalogSliceDrugStoreV9Tests {
    private func makeStore() throws -> (URL, CatalogSliceDrugStore) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drug-v9-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE drug(id INTEGER PRIMARY KEY, region TEXT NOT NULL,
                  source_id TEXT NOT NULL, name_zh TEXT NOT NULL, name_en TEXT,
                  brand_name TEXT, document_source_id TEXT, document_zlib BLOB,
                  document_sha256 BLOB, document_text_bytes INTEGER,
                  document_source_url TEXT, document_fetched_at TEXT,
                  document_match_verified INTEGER)
                """)
            try db.execute(sql: """
                CREATE TABLE drug_sections(drug_id INTEGER NOT NULL, kind TEXT NOT NULL,
                  field TEXT NOT NULL, ordinal INTEGER NOT NULL, value ANY, heading TEXT,
                  PRIMARY KEY(drug_id, kind, field, ordinal))
                """)
            try db.execute(sql: """
                CREATE TABLE drug_reference(drug_id INTEGER NOT NULL, reference_id INTEGER NOT NULL,
                  image_urls_json TEXT NOT NULL, match_status TEXT NOT NULL,
                  PRIMARY KEY(drug_id, reference_id))
                """)
            try db.execute(sql: "CREATE TABLE slice_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: """
                INSERT INTO drug(id, region, source_id, name_zh) VALUES(1, 'CN', 'H1', '甲药')
                """)
            for (field, value) in [("license_no", "国药准字H1"),
                                   ("license_holder", "某控股"),
                                   ("manufacturer", "某药业"),
                                   ("insurance_code", "X1"),
                                   ("drug_code", "D1"),
                                   ("spec", "10mg"),
                                   ("dosage_form", "片剂"),
                                   ("usage_text", "一次1片"),
                                   ("indications", "用于疼痛")] {
                try db.execute(sql: """
                    INSERT INTO drug_sections(drug_id, kind, field, ordinal, value)
                    VALUES(1, 'text', ?, 1, ?)
                    """, arguments: [field, value])
            }
            let meta = [
                "format": "vita-liber-catalog-slice/v1",
                "source_sha256": String(repeating: "a", count: 64),
                "dedupe": "1",
                "tables": #"["drug","drug_reference","drug_sections"]"#,
                "counts": #"{"drug":1,"drug_reference":0,"drug_sections":9}"#,
                "physical_schema": "catalog-v9",
                "source_user_version": "0",
            ]
            for (key, value) in meta {
                try db.execute(sql: "INSERT INTO slice_meta VALUES(?, ?)",
                               arguments: [key, value])
            }
        }
        return (url, try CatalogSliceDrugStore(path: url))
    }

    @Test func registryTextRowsRestoreDrugFields() async throws {
        let (url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }   // try?-ok: 测试清理
        let drug = try #require(try await store.drug(id: 1))
        #expect(drug.nameZh == "甲药")
        #expect(drug.licenseNo == "国药准字H1")
        #expect(drug.licenseHolder == "某控股")
        #expect(drug.manufacturer == "某药业")
        #expect(drug.insuranceCode == "X1")
        #expect(drug.drugCode == "D1")
        #expect(drug.spec == "10mg")
        #expect(drug.dosageForm == "片剂")
    }

    @Test func matchUsesTextRowCodesAndKeepsSpecForNarrowing() async throws {
        let (url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }   // try?-ok: 测试清理
        let now = Date()
        let line = PrescriptionLine(
            prescriptionId: UUID(), patientId: UUID(), ordinal: 1, printedName: "甲药",
            spec: "10mg", insuranceCode: "X1", createdAt: now, updatedAt: now)
        let match = try await store.match(line: line)
        #expect(match.status == .exact)
        #expect(match.exact?.id == 1)
        #expect(match.exact?.spec == "10mg")
    }

    @Test func detailReadsUsageAndIndicationsTextRows() async throws {
        let (url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }   // try?-ok: 测试清理
        let drug = try #require(try await store.drug(id: 1))
        let detail = try #require(try await store.detail(for: drug))
        #expect(detail.usageText == "一次1片")
        #expect(detail.indications == "用于疼痛")
    }
}
#endif
