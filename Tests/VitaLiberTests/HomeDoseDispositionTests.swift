import XCTest
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

// binds: SU-M1c-REGRESSION — TC-M1c-09（BR-004 用药只能显式处置；时段级动作逐剂落 dose_log）
@MainActor
final class HomeDoseDispositionTests: XCTestCase {
    private func makeStore() async throws -> (ReminderStore, MedicationStore, UUID, UUID) {
        let db = try GRDBStore.inMemory()
        let patient = UUID(), med = UUID()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, '测试', '本人', 0, 0)", arguments: [patient.uuidString])
            try db.execute(sql: "INSERT INTO medication (id, patient_id, generic_name, spec, unit_kind, created_at, updated_at) VALUES (?, ?, '阿莫西林', '0.25g', 'tablet', 0, 0)", arguments: [med.uuidString, patient.uuidString])
        }
        let scheduler = InMemoryReminderScheduler()
        let meds = MedicationStore(writer: db.writer)
        let store = ReminderStore(meds: meds, apts: AppointmentStore(writer: db.writer, scheduler: scheduler),
                                  reconciler: ReminderReconciler(scheduler: scheduler, source: meds), scheduler: scheduler,
                                  composer: MedicationPlanComposer(writer: db.writer, audit: AuditLogWriter(writer: db.writer)))
        return (store, meds, patient, med)
    }

    /// 今日 +5 分钟的固定时刻（未决且在今日窗口内；接近日界则跳过）
    private func pendingDoses(_ store: ReminderStore, _ meds: MedicationStore, _ patient: UUID, _ med: UUID) async throws -> [ScheduledDose] {
        let cal = Calendar.current
        let at = cal.date(byAdding: .minute, value: 5, to: Date())!
        try XCTSkipIf(!cal.isDateInToday(at), "接近日界，时段窗口不稳定")
        let hhmm = String(format: "%02d:%02d", cal.component(.hour, from: at), cal.component(.minute, from: at))
        try await meds.createPlan(planId: UUID(), patientId: patient, medicationId: med, schedule: .fixed(times: [hhmm]),
                                  status: .active, startDate: cal.startOfDay(for: Date()), endDate: nil)
        await store.refresh(patientId: patient)
        return store.todaySlots.flatMap(\.records).filter { $0.action == nil }.map(\.dose)
    }

    /// 原名：test_时段跳过逐剂写skipped并返回条数
    func test_timeSlotSkipWritesSkippedPerDoseAndReturnsCount() async throws {
        let (store, meds, patient, med) = try await makeStore()
        let doses = try await pendingDoses(store, meds, patient, med)
        XCTAssertEqual(doses.count, 1)
        let n = await store.skipSlotPending(patientId: patient, doses: doses)   // await 不能进 XCTAssert 自动闭包
        XCTAssertEqual(n, 1)
        XCTAssertEqual(store.todaySlots.flatMap(\.records).first?.action, .skipped)
        XCTAssertEqual(store.pendingCount, 0)
    }

    /// 原名：test_时段稍后先调度后记snoozed
    func test_timeSlotSnoozeSchedulesThenRecordsSnoozed() async throws {
        let (store, meds, patient, med) = try await makeStore()
        let doses = try await pendingDoses(store, meds, patient, med)
        let n = await store.snoozeSlotPending(patientId: patient, doses: doses, minutes: 15)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(store.todaySlots.flatMap(\.records).first?.action, .snoozed)
    }

    /// 原名：test_空剂量集返回0
    func test_emptyDoseSetReturnsZero() async throws {
        let (store, _, patient, _) = try await makeStore()
        let n = await store.skipSlotPending(patientId: patient, doses: [])
        XCTAssertEqual(n, 0)
    }
}
