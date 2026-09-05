import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

// binds: SU-M1b-REMINDER（App 层 ReminderStore 测试——此前零覆盖，
// 全部提醒可靠性用例只落在 Domain 对账套件）

@MainActor
final class ReminderStoreTests: XCTestCase {

    /// 过期提醒 delivered 守卫（FR9.11）：已送达的到期提醒不得重排——
    /// 送达后不再 pending，若无守卫每次 refresh 以同 id 重排 + 重插
    /// recordDelivery（notification_delivery 主键冲突中止循环，其余批次
    /// 静默失去提醒，且已送达提醒死而复生）。
    func test_到期提醒已送达不再重排() async throws {
        let (store, scheduler, db, patient) = try await makeStore()
        let lotId = UUID()
        try await db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO medication (id, patient_id, generic_name, spec, unit_kind, created_at, updated_at)
                VALUES (?, ?, '测试药', '0.5g', 'tablet', 0, 0)
                """, arguments: [UUID().uuidString, patient.uuidString])
            try db.execute(sql: """
                INSERT INTO stock_lot (id, patient_id, medication_id, total_units, unit_kind,
                  remaining_plan_units, remaining_confirmed_units, expire_at, status, last_reconciled_at)
                SELECT ?, patient_id, id, 30, 'tablet', 30, 30, ?, 'active', 0
                FROM medication WHERE generic_name = '测试药'
                """, arguments: [lotId.uuidString, Date().addingTimeInterval(8 * 86400).timeIntervalSince1970])
        }
        // 首次调度：t7（+1d）与 t0（+8d）两档——用 +8d 而非 +7d：
        // fireDates 的 t7 触发点 = expireAt−7 日历日，若 expireAt 恰好 +7d，
        // 触发点即 INSERT 时刻，随后的 now 已越过它（fire >= now 守卫剔除），
        // 断言必然失败（时钟竞态固化进夹具——审查修复）
        var pending = try await scheduler.pending()
        let delivered0 = try await scheduler.delivered()
        await store.scheduleExpiryReminders(patientId: patient, pending: pending, delivered: delivered0)
        pending = try await scheduler.pending()
        let firstIds = Set(pending.keys)
        XCTAssertFalse(firstIds.isEmpty, "首次调度必须产生到期提醒")
        XCTAssertTrue(firstIds.contains("exp-\(lotId.uuidString)-t7"))

        // 模拟系统送达：pending → delivered
        await scheduler.simulateDelivery(upTo: Date().addingTimeInterval(8 * 86400))
        let pendingAfterDelivery = try await scheduler.pending()
        XCTAssertTrue(pendingAfterDelivery.isEmpty)

        // 再次 refresh：delivered 守卫必须阻止重排
        let pending2 = try await scheduler.pending()
        let delivered2 = try await scheduler.delivered()
        await store.scheduleExpiryReminders(patientId: patient, pending: pending2, delivered: delivered2)
        let pendingAfterRefresh = try await scheduler.pending()
        XCTAssertTrue(pendingAfterRefresh.isEmpty,
                      "已送达提醒不得重新调度（无限重发 + delivery 主键冲突）")
    }

    /// FR8.10/FR9.8.3：续药/随访调度写入 route 深链（§5.45 缺路由降级不 crash）
    func test_随访提醒携带观察详情深链() async throws {
        let (store, scheduler, _, patient) = try await makeStore()
        let obsId = UUID()
        await store.scheduleObservationFollowUp(observationId: obsId, observedAt: Date(),
                                                patientId: patient)
        let pending = try await scheduler.pending()
        XCTAssertTrue(pending.keys.contains("followup-\(obsId.uuidString)"))
        let route = await scheduler.route(for: "followup-\(obsId.uuidString)")
        XCTAssertEqual(route, AppRoute.observationDetail(obsId))
    }

    /// BR-012 SOS 误触契约：常规模式 0.6s 长按（误触率 <1% 验收），
    /// 关怀模式按住确认同样生效——视图执法不得出现 0s 立即触发。
    func test_SOS长按契约_常规模式06秒() {
        XCTAssertTrue(SOSRules.requiresHoldConfirm("sos", mode: .standard))
        XCTAssertGreaterThanOrEqual(CareModeMetrics.standard.holdConfirmSeconds, 0.6,
                                    "常规模式 SOS 必须 ≥0.6s 长按（build 147 回归防护）")
        XCTAssertGreaterThanOrEqual(CareModeMetrics.care.holdConfirmSeconds, 0.6,
                                    "关怀模式按住确认同样生效（不得 0s 立即触发）")
    }

    // MARK: - 装配

    private func makeStore() async throws -> (ReminderStore, InMemoryReminderScheduler, GRDBStore, UUID) {
        let db = try GRDBStore.inMemory()
        let patient = UUID()
        try await db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, '测试', '本人', 0, 0)
                """, arguments: [patient.uuidString])
        }
        let scheduler = InMemoryReminderScheduler()
        let meds = MedicationStore(writer: db.writer)
        let apts = AppointmentStore(writer: db.writer, scheduler: scheduler)
        let reconciler = ReminderReconciler(scheduler: scheduler, source: meds)
        let composer = MedicationPlanComposer(writer: db.writer, audit: AuditLogWriter(writer: db.writer))
        let store = ReminderStore(meds: meds, apts: apts, reconciler: reconciler,
                                  scheduler: scheduler, composer: composer)
        return (store, scheduler, db, patient)
    }
}
