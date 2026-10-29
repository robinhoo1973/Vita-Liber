#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Testing
@testable import Domain   // DatabaseBootPolicy（CI 40789487666 红因：漏导入）
@testable import Infrastructure

// binds: SU-M0-DBBOOT（迁移回放矩阵，2026-10-29 转换登记表批 B3）。
// 冻结夹具×崩溃四象限的 Python 半场在 test-schema-integrity.py（Linux 可跑）；
// 本套件补 Swift 引擎侧可机械验证的两格：重复开盘幂等、tooNew fail-closed。
@Suite("SU-M0-DBBOOT · 迁移回放矩阵（引擎侧）")
struct MigrationReplayMatrixTests {
    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-\(UUID().uuidString).sqlite").path
    }

    @Test func repeatOpenAfterFreshIsIdempotent() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) } // try?-ok: 测试清理
        var store: GRDBStore?
        store = try GRDBStore.pool(at: path)
        _ = store
        store = nil   // 释放首开（迁移完成 → user_version = latest）
        let second = try GRDBStore.pool(at: path)   // 二次开盘：pending 为空，必须无副作用通过
        _ = second
        let probe = DatabaseProbe.inspect(
            path: path, requiredTables: DatabaseBootPolicy.requiredTables,
            originalsPresent: false)
        #expect(probe.observedVersion == SchemaMigrations.latestVersion)
        #expect(probe.hasAllRequiredTables)
    }

    @Test func tooNewFailsClosed() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) } // try?-ok: 测试清理
        // 造一个「来自更新版本」的最小库：只写 user_version，不建表——
        // tooNew 守卫在迁移前触发，与表集无关（fail-closed 语义正被测试的点）。
        // 必须落盘到 path（CI 40790911082 红因：漏 path 参数 → 写进了内存队列，
        // pool(at:) 打开的是全新空路径,无异常可抛）。
        let queue = try DatabaseQueue(path: path, configuration: GRDBStore.configuration())
        try queue.write { db in
            try db.execute(sql: "PRAGMA user_version = \(SchemaMigrations.latestVersion + 1)")
        }
        try queue.close()
        // MigrationError 是 GRDBStore 内的 public 嵌套枚举——须限定名
        //（CI 40790219051 红因：裸名不在作用域）。
        #expect(throws: GRDBStore.MigrationError.schemaTooNew(
            found: SchemaMigrations.latestVersion + 1,
            supported: SchemaMigrations.latestVersion)) {
            _ = try GRDBStore.pool(at: path)
        }
        // 源文件绝不被静默改写（fail-closed：打开失败不降级成空库重建）。
        let after = try DatabaseQueue(path: path)
        let version = try after.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
        try after.close()
        #expect(version == SchemaMigrations.latestVersion + 1)
    }
}
#endif
