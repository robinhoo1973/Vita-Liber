#if os(iOS) || os(macOS)
// linux-blind: GRDB 只读/WAL 语义仅 Apple 平台真跑（同 GRDBStore.swift 守卫）。
import XCTest
import Foundation
import GRDB
import Domain
@testable import Infrastructure

/// 只读降级 B0 实验（2026-10-28，规划轮 discussions/2026-10-28-readonly-degradation-round1.md）。
///
/// 目的：关闭 A1–A6 待实测项——
/// - 干净关闭库：readonly 可开？写拒绝错误码恒 8？主库与 `-wal` 字节不变？`user_version` 不变？
/// - 热 WAL（-wal/-shm 在场）：readonly 可开？
/// - 缺 `-shm`：readonly 可开？（GRDB 文档称必败 vs 本仓 probe 先例）
///
/// 纪律：干净关闭态=硬断言（预期已知为真）；热态与缺 -shm 态=**只打印不断言**，
/// 观察值经 CI 日志（XCTest print 直出）回收后再定 PERSIST_WAL 口径。
final class ReadOnlyWALExperimentTests: XCTestCase {

    private func makeDir(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ro-wal-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileDigest(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil } // try?-ok: 实验摘要，读失败按缺文件处理
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    private func listing(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? [] // try?-ok: 实验列举，失败按空目录
    }

    private func readOnlyQueue(_ path: String) throws -> DatabaseQueue {
        var config = GRDBStore.configuration()
        config.readonly = true
        return try DatabaseQueue(path: path, configuration: config)
    }

    // MARK: - 干净关闭态（硬断言）

    func testCleanClosedDatabaseReadsReadOnlyAndRejectsWrites() throws {
        let dir = try makeDir("clean")
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("app-local-user_data.sqlite").path

        // 建库（含迁移到 latest）+ 干净关闭（pool 释放回 checkpoint/清 WAL）。
        var store: GRDBStore? = try GRDBStore.pool(at: path)
        XCTAssertNotNil(store)
        store = nil
        NSLog("B0 clean: files after clean close = \(listing(dir))")

        let versionBefore = try readOnlyQueue(path).read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
        let mainBefore = fileDigest(path)
        let walBefore = fileDigest(path + "-wal")

        let queue = try readOnlyQueue(path)
        let versionRead = try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
        XCTAssertEqual(versionRead, SchemaMigrations.latestVersion, "只读应能读出当前 schema 版本")
        XCTAssertEqual(versionRead, versionBefore)

        // canary 写：必须 SQLite 层拒绝（resultCode 8）。
        do {
            try queue.write { db in try db.execute(sql: "CREATE TABLE b0_canary(x INTEGER)") }
            XCTFail("只读连接写成功——零写红线不成立")
        } catch let error as DatabaseError {
            NSLog("B0 clean: write rejected code=\(error.resultCode.rawValue) extended=\(error.extendedResultCode.rawValue) msg=\(error.message ?? "-")")
            XCTAssertEqual(error.resultCode.rawValue, 8, "只读写拒绝应为 SQLITE_READONLY(8)")
        }

        XCTAssertEqual(fileDigest(path), mainBefore, "只读会话后主库字节必须不变")
        XCTAssertEqual(fileDigest(path + "-wal"), walBefore, "只读会话后 -wal 字节必须不变")
        let versionAfter = try readOnlyQueue(path).read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
        XCTAssertEqual(versionAfter, versionBefore, "只读会话不得推进 user_version")
        NSLog("B0 clean: files after readonly session = \(listing(dir))")
    }

    // MARK: - 热 WAL / 缺 -shm 态（只打印不断言）

    func testHotWALReadOnlyBehaviourIsRecorded() throws {
        let source = try makeDir("hot-src")
        defer { try? FileManager.default.removeItem(at: source) } // try?-ok: 测试清理
        let sourcePath = source.appendingPathComponent("app-local-user_data.sqlite").path

        // 造热 WAL：pool 打开并写入后，拷贝三件套模拟崩溃遗留（-shm 在场）。
        do {
            let pool = try DatabasePool(path: sourcePath, configuration: GRDBStore.configuration())
            try pool.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS b0_hot(x INTEGER)")
                try db.execute(sql: "INSERT INTO b0_hot(x) VALUES (1)")
            }
            let hot = try makeDir("hot-copy")
            defer { try? FileManager.default.removeItem(at: hot) } // try?-ok: 测试清理
            for name in ["app-local-user_data.sqlite", "app-local_user_data.sqlite-wal",
                         "app-local-user_data.sqlite-shm"] {
                let src = source.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: src.path) {
                    try FileManager.default.copyItem(at: src, to: hot.appendingPathComponent(name))
                }
            }
            NSLog("B0 hot: copied files = \(listing(hot))")

            // 1) 带 -shm 的拷贝：readonly DatabaseQueue。
            let hotPath = hot.appendingPathComponent("app-local-user_data.sqlite").path
            do {
                let queue = try readOnlyQueue(hotPath)
                let probe = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM b0_hot") }
                NSLog("B0 hot(+shm): readonly queue OPEN OK, rows=\(String(describing: probe))")
            } catch {
                NSLog("B0 hot(+shm): readonly queue OPEN FAILED: \(error)")
            }
            // 2) 移除 -shm 后再试（GRDB 文档称缺 -shm 只读必败）。
            try? FileManager.default.removeItem(at: hot.appendingPathComponent("app-local-user_data.sqlite-shm")) // try?-ok: 实验清理
            do {
                let queue = try readOnlyQueue(hotPath)
                let probe = try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
                NSLog("B0 hot(-shm): readonly queue OPEN OK, user_version=\(String(describing: probe))")
            } catch {
                NSLog("B0 hot(-shm): readonly queue OPEN FAILED: \(error)")
            }
            // 3) readonly DatabasePool 对照。
            do {
                var config = GRDBStore.configuration()
                config.readonly = true
                let pool = try DatabasePool(path: hotPath, configuration: config)
                let probe = try pool.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
                NSLog("B0 hot(-shm): readonly pool OPEN OK, user_version=\(String(describing: probe))")
            } catch {
                NSLog("B0 hot(-shm): readonly pool OPEN FAILED: \(error)")
            }
            NSLog("B0 hot: files after readonly attempts = \(listing(hot))")
        }
    }
}
#endif
