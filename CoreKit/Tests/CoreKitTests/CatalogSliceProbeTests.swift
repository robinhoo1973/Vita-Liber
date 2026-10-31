#if os(iOS) || os(macOS)
// linux-blind: GRDB only links on Apple platforms; Linux compiles an empty unit.
import Foundation
import GRDB
import Testing
@testable import Domain
@testable import Infrastructure

/// SU-M2-SLICE-PROBE（启动时序批收尾项，2026-10-29；测试席「探针真夹具套件」）：
/// `CatalogSliceProbe.inspectSelfConsistent` 首次直测——合法夹具四 kind 全绿、
/// 契约/表集/计数/坏文件各失败面如实、只读探测零写入（字节守恒）。
// binds: SU-M2-SLICE-PROBE（gate-suites.tsv M0 行；启动时序批收尾项）
@Suite("SU-M2-SLICE-PROBE · 切片自洽探测真夹具")
struct CatalogSliceProbeTests {
    private static let schemaVersion = CatalogSliceProtocol.supportedSliceSchemaVersion

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slice-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha256Hex64() -> String {
        String(repeating: "a", count: 64)
    }

    /// 造一个合法切片库：期望表集 + slice_meta 七硬键；每表恰一行。
    private func makeLegalSlice(at path: String, kind: CatalogSliceKind) throws {
        // 宿主类型实锤=CatalogSliceManifestDecoder（文件名为 CatalogSliceManifest.swift，
        // 类型名与文件不同——CI 40803160846 红因；同 MigrationError 族陷阱）。
        guard let tables = CatalogSliceManifestDecoder.expectedTables(kind, schemaVersion: Self.schemaVersion) else {
            throw CocoaError(.featureUnsupported)
        }
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            for table in tables.sorted() {
                try db.execute(sql: "CREATE TABLE \"\(table)\" (id TEXT PRIMARY KEY, payload TEXT)")
                try db.execute(sql: "INSERT INTO \"\(table)\" (id) VALUES (?)", arguments: ["row-\(table)"])
            }
            try db.execute(sql: "CREATE TABLE slice_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            let countsJSON = try JSONEncoder().encode(
                Dictionary(uniqueKeysWithValues: tables.map { ($0, Int64(1)) }))
            let tablesJSON = try JSONEncoder().encode(Array(tables))
            let rows: [(String, String)] = [
                ("format", CatalogSliceMetaContract.format),
                ("dedupe", "1"),
                ("physical_schema", "catalog-v4"),
                ("source_sha256", sha256Hex64()),
                ("source_user_version", "7"),
                ("tables", String(decoding: tablesJSON, as: UTF8.self)),
                ("counts", String(decoding: countsJSON, as: UTF8.self)),
            ]
            for (key, value) in rows {
                try db.execute(sql: "INSERT INTO slice_meta (key, value) VALUES (?, ?)",
                               arguments: [key, value])
            }
        }
        try queue.close()
    }

    private func fileBytes(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    @Test func legalFixturesReadyForEveryKindAndReadOnlyBytesConserved() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        for kind in CatalogSliceKind.allCases {
            let path = dir.appendingPathComponent("\(kind.stem).sqlite").path
            try makeLegalSlice(at: path, kind: kind)
            let before = try fileBytes(path)
            let state = CatalogSliceProbe.inspectSelfConsistent(path: path, kind: kind)
            guard case .ready(let observed) = state else {
                Issue.record("合法夹具必须 ready：\(kind.rawValue) → \(state)")
                continue
            }
            let expectedTables = CatalogSliceManifestDecoder.expectedTables(kind, schemaVersion: Self.schemaVersion) ?? []
            #expect(observed.tables == Set(expectedTables))
            #expect(observed.physicalSchema == "catalog-v4")
            #expect(try fileBytes(path) == before, "只读探测必须零写入（\(kind.rawValue) 字节守恒）")
        }
    }

    @Test func missingFileIsMissing() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let state = CatalogSliceProbe.inspectSelfConsistent(
            path: dir.appendingPathComponent("absent.sqlite").path, kind: .drug)
        #expect(state == .missing)
    }

    @Test func garbageFileIsUnreadable() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("garbage.sqlite").path
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: path))
        #expect(CatalogSliceProbe.inspectSelfConsistent(path: path, kind: .drug) == .unreadable)
    }

    @Test func missingCountsKeyIsContractViolationAtSelfCheck() throws {
        // v7 探测改为预读全部 slice_meta 后再解析 counts：缺失 counts 属契约
        // 违规（badValue），不再与文件不可读混为一谈。
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("missing-counts.sqlite").path
        try makeLegalSlice(at: path, kind: .facility)
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM slice_meta WHERE key = 'counts'")
        }
        try queue.close()
        #expect(CatalogSliceProbe.inspectSelfConsistent(path: path, kind: .facility)
                == .contractViolation(.badValue("counts")))
    }

    @Test func missingFormatKeyIsViolation() throws {
        // 删 format：counts 仍可预读，后置契约校验可达 → missingKey("format")。
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("missing-format.sqlite").path
        try makeLegalSlice(at: path, kind: .facility)
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM slice_meta WHERE key = 'format'")
        }
        try queue.close()
        #expect(CatalogSliceProbe.inspectSelfConsistent(path: path, kind: .facility)
                == .contractViolation(.missingKey("format")))
    }

    @Test func badPhysicalSchemaIsViolation() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("bad-schema.sqlite").path
        try makeLegalSlice(at: path, kind: .reference)
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "UPDATE slice_meta SET value = 'catalog-v9' WHERE key = 'physical_schema'")
        }
        try queue.close()
        #expect(CatalogSliceProbe.inspectSelfConsistent(path: path, kind: .reference)
                == .contractViolation(.badValue("physical_schema")))
    }

    @Test func extraTableIsTableSetMismatch() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("extra-table.sqlite").path
        try makeLegalSlice(at: path, kind: .drug)
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE catalog_meta (key TEXT PRIMARY KEY, value TEXT)")
        }
        try queue.close()
        // v4 残留表出现即非法（禁 catalog_meta 回落面）。
        #expect(CatalogSliceProbe.inspectSelfConsistent(path: path, kind: .drug)
                == .tableSetMismatch)
    }

    @Test func countDriftIsCountsMismatch() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("count-drift.sqlite").path
        try makeLegalSlice(at: path, kind: .drug)
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO drug (id) VALUES ('second-row')")
        }
        try queue.close()
        // counts 自述仍为 1，实际 2——启动全验（verifyCounts:true）必须拒。
        #expect(CatalogSliceProbe.inspectSelfConsistent(path: path, kind: .drug)
                == .countsMismatch)
    }
}
#endif
