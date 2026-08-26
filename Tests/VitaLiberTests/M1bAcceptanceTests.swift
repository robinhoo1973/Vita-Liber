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
                INSERT INTO medication (id, patient_id, generic_name, unit_kind, created_at, updated_at)
                VALUES (?, ?, '阿莫西林', 'tablet', 0, 0)
                """, arguments: [med.uuidString, patient.uuidString])
        }
        return (store, meds, scheduler, apts, patient, med)
    }

    /// FR9.8.2 双轨扣减矩阵落库：确认「服了」→ 确认线按 FEFO 扣减并写 allocation；
    /// 安全线不受确认动作影响（BR-004）
    func test_双轨扣减矩阵落库() async throws {
        let (store, meds, _, _, patient, med) = try await makeStore()
        // 两批：先到期批 10 粒 + 后到期批 10 粒
        let early = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet",
                                       expireAt: Date(timeIntervalSince1970: 1000))
        let late = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet",
                                      expireAt: Date(timeIntervalSince1970: 2000))
        try await meds.createLot(lot: early, patientId: patient, medicationId: med)
        try await meds.createLot(lot: late, patientId: patient, medicationId: med)

        // 确认「服了 15 粒」→ FEFO：先到期批全扣 10 + 后到期批扣 5
        try await meds.confirmTaken(doseLogId: UUID(), patientId: patient, units: 15)
        let rows = try await store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM stock_lot ORDER BY expire_at")
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["remaining_confirmed_units"] as Double, 0, "先到期批必须全扣（FEFO）")
        XCTAssertEqual(rows[1]["remaining_confirmed_units"] as Double, 5)
        XCTAssertEqual(rows[0]["remaining_plan_units"] as Double, 10, "安全线不受确认动作影响（BR-004）")

        let allocs = try await store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dose_lot_allocation") ?? 0
        }
        XCTAssertEqual(allocs, 2, "每次跨批扣减必须写 allocation 行")
    }

    /// 跳过/忘记零扣减（BR-004 纯事实）
    func test_跳过与忘记零扣减() async throws {
        let (store, meds, _, _, patient, med) = try await makeStore()
        let lot = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet")
        try await meds.createLot(lot: lot, patientId: patient, medicationId: med)
        try await meds.recordAction(doseLogId: UUID(), action: .skipped)
        try await meds.recordAction(doseLogId: UUID(), action: .missed)
        let remaining = try await store.writer.read { db in
            try Double.fetchOne(db, sql: "SELECT remaining_confirmed_units FROM stock_lot") ?? -1
        }
        XCTAssertEqual(remaining, 10, "跳过/忘记不得扣减任何库存（FR9.8.2）")
    }

    /// 预约闭环：创建→四级提醒预排→改期重排→完成状态（FR10.3/10.7）
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

        // 标记完成 → 状态机 completed
        try await apts.complete(id: aptId)
        let status = try await store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM appointment WHERE id = ?",
                                arguments: [aptId.uuidString])
        }
        XCTAssertEqual(status, "completed")

        // 取消 → cancelled + pending 清空
        let apt2 = UUID()
        try await apts.create(id: apt2, patientId: patient, hospital: "仁济",
                              department: "呼吸科", startsAt: startsAt, now: Date())
        try await apts.cancel(id: apt2)
        let remainingApt2 = try await scheduler.pending().keys.filter { $0.hasPrefix("apt-\(apt2.uuidString)") }
        XCTAssertTrue(remainingApt2.isEmpty, "取消后全部 pending 必须移除")
    }
}
