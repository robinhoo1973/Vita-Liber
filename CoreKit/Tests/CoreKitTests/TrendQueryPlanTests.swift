#if os(iOS) || os(macOS)
import Foundation
import Testing
import GRDB
@testable import Domain
@testable import Infrastructure

/// 查询计划断言（2026-09-16 委员会评审）：时间轴主卡查询与指标宫格「每键最新行」
/// 此前无任何计划级守卫——12.7 万行实测每页 490 ms（各分支 `USE TEMP B-TREE FOR
/// ORDER BY`）只在真实病史规模下显形，而测试库是几十行内存库。
/// 本套件是**本仓唯一的 EXPLAIN 层断言**：种子 10k 行 + ANALYZE 后，
/// 断言两条查询走专用索引（v28 `idx_metric_timeline` / `idx_metric_latest`）。
@Suite("SU-M15-TREND · 查询计划断言（v28 索引）")
struct TrendQueryPlanTests {

    private func plan(_ db: Database, _ sql: String, _ args: StatementArguments) throws -> String {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: args)
            .map { ($0["detail"] as String?) ?? "" }
            .joined(separator: " | ")
    }

    /// 10k 行种子 + ANALYZE：规模必须足以让计划器放弃全表扫（小库会选扫表，
    /// 断言会假红）。插入单事务批量，CI 上秒级。
    private func seeded() throws -> GRDBStore {
        let store = try GRDBStore.inMemory()
        try store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES ('p-plan', 'A', 'other', 0, 0)
                """)
            for i in 0..<10_000 {
                try db.execute(sql: """
                    INSERT INTO metric_sample
                      (id, patient_id, metric_key, value, unit, origin, self_measured, excluded,
                       measured_at, created_at)
                    VALUES (?, 'p-plan', ?, ?, 'bpm', ?, 1, 0, ?, ?)
                    """, arguments: [UUID().uuidString, ["heartRate", "steps", "bloodOxygen"][i % 3],
                                     Double(60 + i % 60), i % 4 == 0 ? "device" : "manual",
                                     Double(1_700_000_000 + i * 60), Double(1_700_000_000 + i * 60)])
            }
            try db.execute(sql: "ANALYZE")
        }
        return store
    }

    @Test("v28 两条索引已在基线 DDL 与迁移中定义（新装/升级同形）")
    func 索引存在() throws {
        let store = try seeded()
        let names = try store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='metric_sample'")
        }
        #expect(names.contains("idx_metric_timeline"))
        #expect(names.contains("idx_metric_latest"))
    }

    @Test("时间轴指标分支命中 idx_metric_timeline（不再临时排序）")
    func 时间轴计划() throws {
        let store = try seeded()
        let detail = try store.writer.read { db in
            try plan(db, """
                SELECT id, measured_at, metric_key FROM metric_sample
                WHERE patient_id = ? AND excluded = 0 AND origin = ?
                ORDER BY measured_at DESC, id DESC LIMIT 31
                """, ["p-plan", "device"])
        }
        #expect(detail.contains("idx_metric_timeline"), "计划未走 v28 时间轴索引：\(detail)")
    }

    @Test("宫格最新行命中 idx_metric_latest（分区排序由索引提供）")
    func 宫格计划() throws {
        let store = try seeded()
        let detail = try store.writer.read { db in
            try plan(db, """
                SELECT metric_key, measured_at FROM (
                    SELECT metric_key, measured_at,
                           ROW_NUMBER() OVER (PARTITION BY metric_key
                                              ORDER BY measured_at DESC, rowid DESC) AS rn
                    FROM metric_sample WHERE patient_id = ? AND excluded = 0
                ) WHERE rn = 1
                """, ["p-plan"])
        }
        #expect(detail.contains("idx_metric_latest"), "计划未走 v28 宫格索引：\(detail)")
    }
}
#endif
