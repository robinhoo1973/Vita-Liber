#if os(iOS) || os(macOS)
// linux-blind: GRDB 只读装配语义仅 Apple 平台真跑（同 GRDBStore.swift 守卫）。
import Foundation
import GRDB
import Testing
import Domain
@testable import Infrastructure

/// 只读降级装配面（2026-10-28 规划轮 round1；B0 实证干净关闭库可只读打开）。
/// 钉死：只读打开不建库/不迁移/不写 user_version；写被 SQLite 层拒绝（码 8）；
/// 只读会话后主库与 -wal 字节不变；缺文件只读打开必败（绝不 CREATE）。
@Suite("SU-M2-READONLY-STORE · 只读装配面")
struct ReadOnlyStoreTests {

    private func makeDir(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ro-store-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func digest(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil } // try?-ok: 测试摘要，读失败按缺文件
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    @Test func cleanClosedDatabaseOpensReadOnlyWithoutWrites() throws {
        let dir = try makeDir("clean")
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("app-local-user_data.sqlite").path
        _ = try GRDBStore.pool(at: path)   // 建库+迁移到 latest 后释放（干净关闭）

        let mainBefore = digest(path)
        let walBefore = digest(path + "-wal")

        let store = try GRDBStore.readOnly(at: path)
        let version = try store.writer.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
        #expect(version == SchemaMigrations.latestVersion)

        // 写必须被 SQLite 层拒绝（SQLITE_READONLY 主码 8）。
        do {
            try store.writer.write { db in try db.execute(sql: "CREATE TABLE ro_canary(x INTEGER)") }
            Issue.record("只读连接写成功——零写红线不成立")
        } catch let error as DatabaseError {
            #expect(error.resultCode.rawValue == 8, "只读写拒绝应为 SQLITE_READONLY(8)：\(error.message ?? "-")")
        }

        #expect(digest(path) == mainBefore, "只读会话后主库字节必须不变")
        #expect(digest(path + "-wal") == walBefore, "只读会话后 -wal 字节必须不变")
    }

    @Test func readOnlyOpenNeverRunsMigrationOrAdvancesVersion() throws {
        let dir = try makeDir("nomigrate")
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("app-local-user_data.sqlite").path
        _ = try GRDBStore.pool(at: path)

        // 人工把版本退回 latest-1：RW 打开会迁移，只读绝不允许。
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: "PRAGMA user_version = \(SchemaMigrations.latestVersion - 1)")
        }
        let digestBefore = digest(path)

        let store = try GRDBStore.readOnly(at: path)
        let version = try store.writer.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
        #expect(version == SchemaMigrations.latestVersion - 1, "只读打开不得推进 user_version")
        #expect(digest(path) == digestBefore, "只读打开不得写库（迁移字节变化可检出）")
    }

    @Test func readOnlyOpenRefusesToCreateMissingFile() throws {
        let dir = try makeDir("missing")
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("absent.sqlite").path
        #expect(throws: (any Error).self) {
            _ = try GRDBStore.readOnly(at: path)
        }
        #expect(!FileManager.default.fileExists(atPath: path), "只读打开绝不得 CREATE 空库")
    }
}
#endif
