import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

// binds: SU-M2-STOCK — TC-M2-01 零确认存活（落库链）+ FR9.8.5 月报 + 盘点归真
/// M2 双轨库存的 GRDB 落库半场（test-plan §4.5 TC-M2-01/02）。
///
/// Domain 半场（refillTiersFired / advancePlanTrack）在 CoreKitTests；这里验证
/// **生产链**：排程物化 → 零用户动作 → `materializeMissed` 补账 → 安全线按计划
/// 推进、确认线不动 → 续药档位随安全线触达 → 月报纯事实。
@MainActor
final class M2StockAcceptanceTests: XCTestCase {

    private func makeStore() async throws -> (GRDBStore, MedicationStore, UUID, UUID) {
        let store = try GRDBStore.inMemory()
        let meds = MedicationStore(writer: store.writer)
        let patient = UUID()
        let med = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, '零确认测试患者', '本人', 0, 0)
                """, arguments: [patient.uuidString])
            try db.execute(sql: """
                INSERT INTO medication (id, patient_id, generic_name, spec, unit_kind, created_at, updated_at)
                VALUES (?, ?, '二甲双胍', '0.5g', 'tablet', 0, 0)
                """, arguments: [med.uuidString, patient.uuidString])
        }
        return (store, meds, patient, med)
    }

    /// 时区固定 Asia/Shanghai 的日历（对账/物化的时区语义依赖）
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    /// **M2 一票否决（FR9.8.8）**：建计划 → 物化窗口 → 零确认零动作 →
    /// 补账把过期剂量物化为 missed，安全线按计划推进、确认线分毫不动，
    /// 续药档位照常按安全线触达。
    func test_零确认存活_补账驱动安全线推进且确认线不动() async throws {
        let (store, meds, patient, med) = try await makeStore()
        let lot = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet")
        try await meds.createLot(lot: lot, patientId: patient, medicationId: med)

        // 计划从「4 天前」开始、每天 08:00 一剂；今天把窗口物化出来
        let planStart = cal.date(byAdding: .day, value: -4, to: Date())!
        let planId = UUID()
        try await meds.createPlan(planId: planId, patientId: patient, medicationId: med,
                                  schedule: .fixed(times: ["08:00"]), status: .active,
                                  startDate: planStart, endDate: nil)
        let inserted = try await meds.materializeWindow(now: Date(), calendar: cal)
        XCTAssertGreaterThan(inserted, 0, "前置：窗口内必须物化出剂量行")

        // —— 零确认存活的核心：一个动作都不做，只推进补账 ——
        let missed = try await meds.materializeMissed(now: Date())

        let rows = try await store.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.user_action, l.remaining_plan_units, l.remaining_confirmed_units
                FROM medication_dose_log d, stock_lot l
                WHERE l.id = ?
                """, arguments: [lot.lotId.uuidString])
        }
        XCTAssertGreaterThan(missed, 0, "零动作下必须补账出 missed 剂量")
        XCTAssertEqual((rows.last?["remaining_plan_units"] as Double?) ?? 0,
                       10 - Double(missed),
                       "安全线必须按计划推进（排程驱动，不依赖用户动作）")
        XCTAssertEqual((rows.last?["remaining_confirmed_units"] as Double?) ?? -1, 10,
                       "确认线分毫不动（BR-004：只有「服了」才扣）")
        XCTAssertTrue(rows.allSatisfy { ($0["user_action"] as String?) == "missed" },
                      "所有过期行都必须物化为 missed，不得留下 user_action IS NULL 的僵尸行")

        // 幂等：重复补账不得重复扣减（user_action IS NULL 守卫）
        let again = try await meds.materializeMissed(now: Date())
        XCTAssertEqual(again, 0, "补账必须幂等——重复调用不得再扣安全线")

        // 续药档位照常触达：余 6 天 → 命中 ≤7 档（零确认存活闭环）
        let summary = try await meds.inventorySummary(patientId: patient, now: Date())
        let item = try XCTUnwrap(summary.first { $0.lotId == lot.lotId })
        XCTAssertEqual(item.remainingPlanUnits, 10 - Double(missed))
        XCTAssertNotNil(item.refillTier, "零确认下续药提醒必须照常分级触达（FR9.8.8）")
    }

    /// 补账幂等并发安全：已决议行绝不重复扣（UPDATE ... WHERE user_action IS NULL
    /// + changesCount 判定）
    func test_补账幂等且不重复扣减() async throws {
        let (store, meds, patient, med) = try await makeStore()
        let lot = DualTrackInventory(lotId: UUID(), totalUnits: 5, unitKind: "tablet")
        try await meds.createLot(lot: lot, patientId: patient, medicationId: med)
        let planId = UUID()
        try await meds.createPlan(planId: planId, patientId: patient, medicationId: med,
                                  schedule: .fixed(times: ["08:00"]), status: .active,
                                  startDate: cal.date(byAdding: .day, value: -2, to: Date())!,
                                  endDate: nil)
        _ = try await meds.materializeWindow(now: Date(), calendar: cal)

        let first = try await meds.materializeMissed(now: Date())
        let second = try await meds.materializeMissed(now: Date())
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(second, 0)
        let plan = try await store.writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT remaining_plan_units FROM stock_lot WHERE id = ?
                """, arguments: [lot.lotId.uuidString])
        }
        XCTAssertEqual((plan?["remaining_plan_units"] as Double?) ?? -1, 5 - Double(first),
                       "两次补账合计只扣 first 次")
    }

    /// FR9.8.5 消耗差异月报：数据源 = 两线差值（dose_log 事实），逐日可溯、
    /// 纯事实句式过负清单
    func test_差异月报纯事实且过负清单() async throws {
        let (store, meds, patient, med) = try await makeStore()
        let lot = DualTrackInventory(lotId: UUID(), totalUnits: 20, unitKind: "tablet")
        try await meds.createLot(lot: lot, patientId: patient, medicationId: med)
        let planId = UUID()
        try await meds.createPlan(planId: planId, patientId: patient, medicationId: med,
                                  schedule: .fixed(times: ["08:00"]), status: .active,
                                  startDate: cal.date(byAdding: .day, value: -4, to: Date())!,
                                  endDate: nil)
        _ = try await meds.materializeWindow(now: Date(), calendar: cal)

        // 一天前的一剂已「服了」，其余全部零动作
        let ids = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM medication_dose_log ORDER BY scheduled_for")
        }
        XCTAssertFalse(ids.isEmpty)
        if let earliest = ids.first {
            // 早于宽限期的已过期行先补账（此时全部为 missed）
            _ = try await meds.materializeMissed(now: Date())
            // 无法补录已决议行——直接落一条 taken 行作「已服」事实（月报只读行）
            try await store.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO medication_dose_log
                      (id, plan_id, scheduled_for, dose_units, delivery_state, user_action, acted_at)
                    VALUES (?, ?, ?, 1, 'delivered', 'taken', ?)
                    """, arguments: [UUID().uuidString, planId.uuidString,
                                     Date().timeIntervalSince1970 - 3600,
                                     Date().timeIntervalSince1970])
            }
        }
        let monthStart = cal.date(byAdding: .day, value: -30, to: Date())!
        let report = try await meds.monthlyReport(patientId: patient,
                                                  from: monthStart, to: Date())
        XCTAssertTrue(report.statement.contains("计划 \(report.plannedDoses) 次"))
        XCTAssertTrue(report.statement.contains("确认 \(report.confirmedDoses) 次"))
        XCTAssertEqual(report.confirmedDoses, 1, "唯一一条 taken 事实计入确认")
        XCTAssertNil(InventoryReportRules.violation(in: report.statement),
                     "月报出现评价/建议句式即一票否决（FR9.8.5）")
    }

    /// 盘点归真（FR9.8.5 往返）：账面 8 → 实物清点 3 → 两线同时重置为 3，
    /// 差异必须经 Domain 确认语义（needsConfirmation）
    func test_盘点归真往返两线重置() async throws {
        let (store, meds, patient, med) = try await makeStore()
        let lot = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet")
        try await meds.createLot(lot: lot, patientId: patient, medicationId: med)
        try await meds.reconcileLot(lotId: lot.lotId, physicalCount: 3, at: Date())

        let row = try await store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM stock_lot WHERE id = ?",
                             arguments: [lot.lotId.uuidString])
        }
        XCTAssertEqual((row?["remaining_plan_units"] as Double?) ?? -1, 3)
        XCTAssertEqual((row?["remaining_confirmed_units"] as Double?) ?? -1, 3)
        XCTAssertNotNil(row?["last_reconciled_at"])

        // 归真语义：差异非零必须要求确认（Domain 判据）
        let book = InventoryReconciliation(lotId: lot.lotId, bookConfirmed: 8,
                                           physicalCount: 3, resolvedAt: Date())
        XCTAssertTrue(book.needsConfirmation, "归真差异必须经用户确认才写回")
    }

    /// 「约剩 N 天·按计划估算」的诚实性：daily=1 时 N=剩余安全线，绝不超过
    func test_诚实性天数估算() async throws {
        let (store, meds, patient, med) = try await makeStore()
        let lot = DualTrackInventory(lotId: UUID(), totalUnits: 7, unitKind: "tablet")
        try await meds.createLot(lot: lot, patientId: patient, medicationId: med)
        let planId = UUID()
        try await meds.createPlan(planId: planId, patientId: patient, medicationId: med,
                                  schedule: .fixed(times: ["08:00"]), status: .active,
                                  startDate: Date(), endDate: nil)
        let summary = try await meds.inventorySummary(patientId: patient, now: Date())
        let item = try XCTUnwrap(summary.first)
        XCTAssertEqual(item.approxDaysLeft, 7, "约剩 7 天 · 按计划估算")
        XCTAssertEqual(item.refillTier, .t7, "余 7 天命中 ≤7 档")
        XCTAssertEqual(item.medicationName, "二甲双胍")
    }
}
