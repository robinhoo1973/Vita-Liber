import Foundation
import SwiftUI
import os
import Domain
import Infrastructure
import Protocols

/// M1b 提醒模块状态仓（@Observable）：
/// 今日时段聚合（FR9.17）+ 服药确认动作集 + 预约闭环 + 对账触发。
@MainActor
@Observable
final class ReminderStore {
    private(set) var todaySlots: [DoseSlot] = []
    private(set) var upcomingAppointments: [AppointmentRow] = []
    private(set) var loading = false

    private let meds: MedicationStore
    private let apts: AppointmentStore
    private let reconciler: ReminderReconciler
    private let logger = Logger(subsystem: "com.vitaliber", category: "reminders")

    init(meds: MedicationStore, apts: AppointmentStore, reconciler: ReminderReconciler) {
        self.meds = meds
        self.apts = apts
        self.reconciler = reconciler
    }

    /// 四层补偿的入口统一走 reconcile；加载今日视图数据
    func refresh(patientId: UUID?, now: Date = Date()) async {
        loading = true
        defer { loading = false }
        await reconciler.reconcile(now: now)
        guard let patientId else { return }
        do {
            let dayStart = Calendar.current.startOfDay(for: now)
            let dayEnd = dayStart.addingTimeInterval(86400)
            let facts = try await meds.deliveryFacts(from: dayStart, to: dayEnd)
            let records = facts.map { DoseRecord(dose: $0.dose, action: $0.action) }
            todaySlots = DoseSlotGrouping.group(records)
            upcomingAppointments = try await apts.upcoming(patientId: patientId, now: now)
        } catch {
            logger.error("提醒视图加载失败: \(error)")
        }
    }

    /// 服药确认动作集（FR9.7）：服了→扣减；跳过/稍后→只写动作（BR-004 永不推断病因）
    func confirmTaken(patientId: UUID, dose: ScheduledDose) async {
        do {
            try await meds.confirmTaken(doseLogId: UUID(), patientId: patientId, units: dose.doseUnits)
            await refresh(patientId: patientId)
        } catch {
            logger.error("确认服药失败: \(error)")
        }
    }

    func skipDose(dose: ScheduledDose) async {
        do {
            try await meds.recordAction(doseLogId: UUID(), action: .skipped)
        } catch {
            logger.error("跳过记录失败: \(error)")
        }
    }

    func snoozeDose(dose: ScheduledDose, minutes: Int = 15, patientId: UUID?) async {
        // 稍后提醒 = 取消原通知 + 新 trigger（§5.4）；M1b 以对账侧动作落库占位
        do {
            try await meds.recordAction(doseLogId: UUID(), action: .snoozed)
            if let patientId { await refresh(patientId: patientId) }
        } catch {
            logger.error("稍后提醒失败: \(error)")
        }
    }

    func createAppointment(patientId: UUID, hospital: String, department: String,
                           startsAt: Date) async {
        do {
            try await apts.create(patientId: patientId, hospital: hospital,
                                  department: department, startsAt: startsAt, now: Date())
            await refresh(patientId: patientId)
        } catch {
            logger.error("预约创建失败: \(error)")
        }
    }
}
