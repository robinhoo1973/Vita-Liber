import Foundation
import Testing
@testable import Infrastructure

/// slice_meta 契约金样（B0 契约件；纯 Foundation，Linux 真跑）。
/// 行样例取自 f7 拆分器实样（key/value 行；tables 按源序、counts 排序键）。
@Suite("SU-M2-SLICE · slice_meta 契约")
struct CatalogSliceMetaContractTests {

    private let sourceSHA = String(repeating: "a", count: 64)

    private func rows(tables: String = "[\"hospital\", \"department\"]",
                      counts: String = "{\"department\": 172, \"hospital\": 28573}",
                      overrides: [String: String] = [:],
                      drop: [String] = []) -> [(key: String, value: String)] {
        var values: [String: String] = [
            "format": "vita-liber-catalog-slice/v1",
            "source_sha256": sourceSHA,
            "created_at": "2026-10-27T16:20:56Z",
            "dedupe": "1",
            "tables": tables,
            "counts": counts,
            "physical_schema": "catalog-v4",
            "source_user_version": "9",
        ]
        for (key, value) in overrides { values[key] = value }
        for key in drop { values.removeValue(forKey: key) }
        return values.map { (key: $0.key, value: $0.value) }
    }

    private let expectedTables: Set<String> = ["hospital", "department"]
    private let expectedCounts: [String: Int64] = ["department": 172, "hospital": 28_573]

    @Test("实样行通过；顺序无关；未知键忽略")
    func validatesRealShape() throws {
        let observed = try CatalogSliceMetaContract.validate(
            rows: rows(), expectedTables: expectedTables, expectedCounts: expectedCounts)
        #expect(observed.physicalSchema == "catalog-v4")
        #expect(observed.sourceUserVersion == 9)
        #expect(observed.tables == expectedTables)
        // 未知键忽略（created_at 本非硬验键）
        _ = try CatalogSliceMetaContract.validate(
            rows: rows(overrides: ["future_diagnostic": "x"]),
            expectedTables: expectedTables, expectedCounts: expectedCounts)
    }

    @Test("缺键/重复键/坏形态一律拒")
    func strictKeysAndValues() {
        #expect(throws: CatalogSliceMetaContract.Violation.missingKey("physical_schema")) {
            _ = try CatalogSliceMetaContract.validate(
                rows: rows(drop: ["physical_schema"]),
                expectedTables: expectedTables, expectedCounts: expectedCounts)
        }
        #expect(throws: CatalogSliceMetaContract.Violation.missingKey("source_user_version")) {
            _ = try CatalogSliceMetaContract.validate(
                rows: rows(drop: ["source_user_version"]),
                expectedTables: expectedTables, expectedCounts: expectedCounts)
        }
        var duplicated = rows()
        duplicated.append((key: "format", value: "vita-liber-catalog-slice/v1"))
        #expect(throws: CatalogSliceMetaContract.Violation.duplicateKey("format")) {
            _ = try CatalogSliceMetaContract.validate(
                rows: duplicated, expectedTables: expectedTables, expectedCounts: expectedCounts)
        }
        #expect(throws: CatalogSliceMetaContract.Violation.badValue("dedupe")) {
            _ = try CatalogSliceMetaContract.validate(
                rows: rows(overrides: ["dedupe": "0"]),
                expectedTables: expectedTables, expectedCounts: expectedCounts)
        }
        #expect(throws: CatalogSliceMetaContract.Violation.badValue("format")) {
            _ = try CatalogSliceMetaContract.validate(
                rows: rows(overrides: ["format": "vita-liber-catalog-slice/v2"]),
                expectedTables: expectedTables, expectedCounts: expectedCounts)
        }
        #expect(throws: CatalogSliceMetaContract.Violation.badValue("source_sha256")) {
            _ = try CatalogSliceMetaContract.validate(
                rows: rows(overrides: ["source_sha256": String(repeating: "A", count: 64)]),
                expectedTables: expectedTables, expectedCounts: expectedCounts)
        }
        #expect(throws: CatalogSliceMetaContract.Violation.badValue("physical_schema")) {
            _ = try CatalogSliceMetaContract.validate(
                rows: rows(overrides: ["physical_schema": "catalog-v9"]),
                expectedTables: expectedTables, expectedCounts: expectedCounts)
        }
        #expect(throws: CatalogSliceMetaContract.Violation.badValue("source_user_version")) {
            _ = try CatalogSliceMetaContract.validate(
                rows: rows(overrides: ["source_user_version": "nine"]),
                expectedTables: expectedTables, expectedCounts: expectedCounts)
        }
    }

    @Test("tables/counts 与 manifest 三方一致（顺序无关；浮动值拒）")
    func tablesAndCountsAgreement() {
        _ = try? CatalogSliceMetaContract.validate(   // try?-ok: 本断言只为覆写前的通过性，失败在下方专项断言
            rows: rows(tables: "[\"department\", \"hospital\"]"),
            expectedTables: expectedTables, expectedCounts: expectedCounts)
        #expect(throws: CatalogSliceMetaContract.Violation.tablesMismatch) {
            _ = try CatalogSliceMetaContract.validate(
                rows: rows(tables: "[\"hospital\", \"department\", \"extra\"]"),
                expectedTables: expectedTables, expectedCounts: expectedCounts)
        }
        #expect(throws: CatalogSliceMetaContract.Violation.countsMismatch) {
            _ = try CatalogSliceMetaContract.validate(
                rows: rows(counts: "{\"department\": 173, \"hospital\": 28573}"),
                expectedTables: expectedTables, expectedCounts: expectedCounts)
        }
        #expect(throws: CatalogSliceMetaContract.Violation.badValue("counts")) {
            _ = try CatalogSliceMetaContract.validate(
                rows: rows(counts: "{\"department\": 172.5, \"hospital\": 28573}"),
                expectedTables: expectedTables, expectedCounts: expectedCounts)
        }
        #expect(throws: CatalogSliceMetaContract.Violation.badValue("tables")) {
            _ = try CatalogSliceMetaContract.validate(
                rows: rows(tables: "not json"),
                expectedTables: expectedTables, expectedCounts: expectedCounts)
        }
    }
}
