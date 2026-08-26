import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

/// TC-M1b 双轨扣减矩阵与预约闭环（test-plan §4.3）——GRDB 落库级断言
@MainActor
final class M1bAcceptanceTests: XCTestCase {

    private func makeStore() async throws -> (store: GRDBStore, meds: MedicationStore, scheduler: InMemoryReminderScheduler, apts: AppointmentStore, patient: UUID, med: UUID) {
        let store = try GRDBStore.inMemory()
        let scheduler = InMemoryReminderScheduler()
        let meds = MedicationStore(writer: store.writer)
        let apts = AppointmentStore(writer: store.writer, scheduler: scheduler)
        // 种子数据：patient_profile + medication（stock_lot 的外键目标，ERR#35 教训前置）
        let patient = UUID()
        let med = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, '测试患者', '本人', 0, 0)
                """, arguments: [patient.uuidString])
            try db.execute(sql: """
                INSERT INTO medication (id, patient_id, generic_name, spec, unit_kind, created_at, updated_at)
                VALUES (?, ?, '阿莫西林', '0.25g', 'tablet', 0, 0)
                """, arguments: [med.uuidString, patient.uuidString])
        }
        return (store, meds, scheduler, apts, patient, med)
    }

    /// 创建 active 计划并物化今日窗口，返回首个剂量 notifyId
    private func materializedDose(store: GRDBStore, meds: MedicationStore, patient: UUID, med: UUID,
                                  times: [String] = ["08:00"]) async throws -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let planId = UUID()
        try await meds.createPlan(planId: planId, patientId: patient, medicationId: med,
                                  schedule: .fixed(times: times), status: .active,
                                  startDate: cal.startOfDay(for: Date()), endDate: nil)
        _ = try await meds.materializeWindow(now: Date(), calendar: cal)
        let ids = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM medication_dose_log ORDER BY scheduled_for LIMIT 1")
        }
        return try XCTUnwrap(ids.first)
    }

    /// FR9.8.2 双轨扣减矩阵落库（评审修正）：taken → 两线各扣 + allocation；
    /// 动作 UPDATE 物化行（非孤儿行）→ deliveryFacts 可见已服
    func test_双轨扣减矩阵落库() async throws {
        let (store, meds, _, _, patient, med) = try await makeStore()
        let early = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet",
                                       expireAt: Date(timeIntervalSince1970: 9999999999))
        let late = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet",
                                      expireAt: Date(timeIntervalSince1970: 99999999999))
        try await meds.createLot(lot: early, patientId: patient, medicationId: med)
        try await meds.createLot(lot: late, patientId: patient, medicationId: med)

        let notifyId = try await materializedDose(store: store, meds: meds, patient: patient, med: med)
        try await meds.confirmTaken(notifyId: notifyId, patientId: patient)

        let rows = try await store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM stock_lot ORDER BY expire_at")
        }
        // FEFO：先到期批扣完，两线同步各扣 1（dose_units=1）
        XCTAssertEqual(rows[0]["remaining_confirmed_units"] as Double, 9)
        XCTAssertEqual(rows[0]["remaining_plan_units"] as Double, 9, "FR9.8.2：已服两线各扣")
        XCTAssertEqual(rows[1]["remaining_confirmed_units"] as Double, 10, "FEFO：后到期批不动")

        // 幂等（S0-2）：重复确认必须被拒
        do {
            try await meds.confirmTaken(notifyId: notifyId, patientId: patient)
            XCTFail("已决议行重复确认必须抛错")
        } catch {
            // 期望 alreadyResolved
        }

        // 动作对事实链可见（BR-004 生产链闭环）
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let dayStart = cal.startOfDay(for: Date())
        let facts = try await meds.deliveryFacts(from: dayStart, to: dayStart.addingTimeInterval(86400))
        XCTAssertTrue(facts.contains { $0.action == .taken && $0.dose.notifyId == notifyId },
                      "已服动作必须对 deliveryFacts 可见（不再重发、不再重复扣减）")
    }

    /// 跳过：仅计划轨扣；确认线不动（BR-004）
    func test_跳过仅计划轨扣() async throws {
        let (store, meds, _, _, patient, med) = try await makeStore()
        let lot = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet",
                                     expireAt: Date(timeIntervalSince1970: 9999999999))
        try await meds.createLot(lot: lot, patientId: patient, medicationId: med)
        let notifyId = try await materializedDose(store: store, meds: meds, patient: patient, med: med)
        try await meds.recordAction(notifyId: notifyId, action: .skipped)
        let row = try await store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM stock_lot")
        }
        let unwrapped = try XCTUnwrap(row)
        XCTAssertEqual(unwrapped["remaining_plan_units"] as Double, 9, "跳过扣计划轨")
        XCTAssertEqual(unwrapped["remaining_confirmed_units"] as Double, 10, "跳过不扣确认线（BR-004）")
    }

    /// 计划→剂量物化→对账事实 数据链闭合 + 老计划窗口锚定（S0-3 修正）
    func test_老计划窗口锚定今天() async throws {
        let (store, meds, _, _, patient, med) = try await makeStore()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let planId = UUID()
        // 计划 30 天前开立——旧实现 fromDay 固定 1 会物化 0 行
        let start = cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: Date()))!
        try await meds.createPlan(planId: planId, patientId: patient, medicationId: med,
                                  schedule: .fixed(times: ["08:00", "20:00"]),
                                  status: .active, startDate: start, endDate: nil)
        let inserted = try await meds.materializeWindow(now: Date(), calendar: cal)
        XCTAssertGreaterThan(inserted, 0, "老计划也必须物化今日起的窗口（窗口以 now 锚定）")
        let todayRows = try await store.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM medication_dose_log
                WHERE scheduled_for >= ?
                """, arguments: [cal.startOfDay(for: Date()).timeIntervalSince1970]) ?? 0
        }
        XCTAssertGreaterThanOrEqual(todayRows, 1, "今日窗口必须存在剂量行")
    }

    /// 预约闭环：创建→四级提醒预排→改期重排→完成（含补录就诊）→取消清 pending
    func test_预约创建分级提醒与改期() async throws {
        let (store, _, scheduler, apts, patient, _) = try await makeStore()
        let startsAt = Date().addingTimeInterval(10 * 86400)
        let aptId = UUID()
        try await apts.create(id: aptId, patientId: patient, hospital: "市一医院",
                              department: "心内科", startsAt: startsAt, now: Date())
        var pending = try await scheduler.pending()
        XCTAssertEqual(pending.count, 4, "四级触发点必须全部预排")
        XCTAssertTrue(pending.keys.allSatisfy { $0.hasPrefix("apt-\(aptId.uuidString)") })

        // 改期 → 旧 tiers 全取消 + 新 tiers 重排（幂等）
        let newStarts = startsAt.addingTimeInterval(86400)
        try await apts.reschedule(id: aptId, startsAt: newStarts, now: Date())
        pending = try await scheduler.pending()
        XCTAssertEqual(pending.count, 4)

        // 标记完成 → completed + 补录就诊（评审修正 P0：闭环含 F4 encounter）
        try await apts.complete(id: aptId)
        let status = try await store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM appointment WHERE id = ?",
                                arguments: [aptId.uuidString])
        }
        XCTAssertEqual(status, "completed")
        let encounterCount = try await store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM encounter WHERE patient_id = ?",
                             arguments: [patient.uuidString]) ?? 0
        }
        XCTAssertEqual(encounterCount, 1, "标记完成必须补录就诊行（预约闭环）")

        // 取消 → cancelled + pending 清空
        let apt2 = UUID()
        try await apts.create(id: apt2, patientId: patient, hospital: "仁济",
                              department: "呼吸科", startsAt: startsAt, now: Date())
        try await apts.cancel(id: apt2)
        let remainingApt2 = try await scheduler.pending().keys.filter { $0.hasPrefix("apt-\(apt2.uuidString)") }
        XCTAssertTrue(remainingApt2.isEmpty, "取消后全部 pending 必须移除")
    }
}
