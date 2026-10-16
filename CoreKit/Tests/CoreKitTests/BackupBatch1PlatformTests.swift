import Foundation
import Testing
#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：ExportService/AuditLogWriter 整文件在 Linux 编译为空单元，本套件仅 macOS CI 执行）
import GRDB
@testable import Infrastructure

/// 备份批次 1 平台面测试（discussions/2026-10-16-backup-sync-share-design.md V1.7 切片 3，macOS CI）：
/// - 冲突 id 分块 IN 查询（1200 id 跨 500/批，不触碰 SQLite 变量上限）
/// - 审计四动作（restore/import/share/sync）白名单成员与常量一致
struct BackupBatch1PlatformTests {

    @Test func chunkedIDLookupCrossesBatchBoundary() throws {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.execute(sql: "CREATE TABLE probe(id TEXT PRIMARY KEY)")
            for i in 0..<1200 {
                try db.execute(sql: "INSERT INTO probe(id) VALUES (?)", arguments: [String(format: "id-%04d", i)])
            }
        }
        let ids = (0..<1200).map { String(format: "id-%04d", $0) } + ["missing-1", "missing-2"]
        let found = try db.read { db in
            try ExportService.chunkedIDLookup(db, table: "probe", ids: ids)
        }
        #expect(found.count == 1200)   // 3 批跨块拼接无缺漏
        #expect(Set(found) == Set((0..<1200).map { String(format: "id-%04d", $0) }))
    }

    @Test func auditFourActionsWhitelisted() {
        for action in [AuditLogWriter.Action.restore, AuditLogWriter.Action.import,
                       AuditLogWriter.Action.share, AuditLogWriter.Action.sync] {
            #expect(AuditLogWriter.allowedActions.contains(action))
        }
    }
}
#endif
