import Foundation
import SwiftUI
import os
import UserNotifications
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

    /// FR14.8/SP-27: Unread reminder count for tab badge.
    /// Counts doses with no user action across all today's slots.
    var pendingCount: Int {
        todaySlots.reduce(0) { $0 + $1.records.filter { $0.action == nil }.count }
    }

    private let meds: MedicationStore
    private let apts: AppointmentStore
    private let reconciler: ReminderReconciler
    private let logger = Logger(subsystem: "com.vitaliber", category: "reminders")
    /// 关怀模式震颤防抖（F18）：同一动作按钮的最近一次触发时刻；
    /// 连续重复点击在防抖窗口内只计一次（TremorGuard 是 Domain 纯函数）
    private var lastActionAt: Date?

    /// 最近一次请求的成员（BR-001 成员隔离：只允许最新请求写回状态）
    private var loadingPatientId: UUID?

    init(meds: MedicationStore, apts: AppointmentStore, reconciler: ReminderReconciler) {
        self.meds = meds
        self.apts = apts
        self.reconciler = reconciler
    }

    /// 四层补偿的入口统一走 reconcile；加载今日视图数据。
    /// 先物化滚动预排窗口（active 计划 → 7 天剂量行），再对账、再读今日时段。
    func refresh(patientId: UUID?, now: Date = Date()) async {
        loading = true
        defer { loading = false }
        guard let patientId else { return }
        loadingPatientId = patientId
        do {
            _ = try await meds.materializeWindow(now: now, calendar: .current)
            // FR9.8.8 零确认存活：先补账过期无动作剂量（安全线按计划推进），
            // 再对账——顺序不可反。对账只调度「未决剂量」，不产生用户动作；
            // 若先对账后补账，已过宽限的零确认剂量会从事实链里消失，
            // 安全线永不下行、续药提醒永不触发（M2 一票否决的失效形态）。
            _ = try await meds.materializeMissed(now: now)
            await reconciler.reconcile(now: now)
            let cal = Calendar.current
            let dayStart = cal.startOfDay(for: now)
            // S2-2 修正：DST 日 23/25 小时——日界必须用日历加一天，禁止 +86400 秒
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
            let facts = try await meds.deliveryFacts(from: dayStart, to: dayEnd)
            let records = facts.map { DoseRecord(dose: $0.dose, action: $0.action) }
            let slots = DoseSlotGrouping.group(records)
            let appointments = try await apts.upcoming(patientId: patientId, now: now)
            // 成员切换后晚到的旧结果必须丢弃，不得覆盖当前成员（BR-001）
            guard loadingPatientId == patientId else { return }
            todaySlots = slots
            upcomingAppointments = appointments
        } catch {
            logger.error("提醒视图加载失败: \(error)")
        }
    }

    /// 服药确认动作集（FR9.7）：动作按 notifyId UPDATE 物化行（评审修正 P0）。
    /// careMode=true 时经 TremorGuard 防抖——震颤模拟下连续重复点击只计一次
    /// （F18 关怀模式验收的落点；Domain 纯函数，本层只做门卫）。
    func confirmTaken(patientId: UUID, dose: ScheduledDose, careMode: Bool = false) async {
        guard tremorAccepted(careMode: careMode) else { return }
        do {
            try await meds.confirmTaken(notifyId: dose.notifyId, patientId: patientId)
            await refresh(patientId: patientId)
        } catch {
            logger.error("确认服药失败: \(error)")
        }
    }

    func skipDose(dose: ScheduledDose, careMode: Bool = false) async {
        guard tremorAccepted(careMode: careMode) else { return }
        do {
            try await meds.recordAction(notifyId: dose.notifyId, action: .skipped)
        } catch {
            logger.error("跳过记录失败: \(error)")
        }
    }

    func snoozeDose(dose: ScheduledDose, minutes: Int = 15, patientId: UUID?, careMode: Bool = false) async {
        guard tremorAccepted(careMode: careMode) else { return }
        do {
            try await meds.recordAction(notifyId: dose.notifyId, action: .snoozed)
            // S1-2 修正：稍后=取消时段通知 + 按新时刻单排（FR9.5）
            let slotId = DoseSlotGrouping.slotId(for: DoseRecord(dose: dose)).map { "slot-\($0)" }
            await reconciler.snooze(doseNotifyId: dose.notifyId, slotNotifyId: slotId,
                                    until: Date().addingTimeInterval(TimeInterval(minutes * 60)))
            if let patientId { await refresh(patientId: patientId) }
        } catch {
            logger.error("稍后提醒失败: \(error)")
        }
    }

    /// 震颤防抖门卫（F18）：常规模式不设防（零延迟），关怀模式 0.3s 窗口内
    /// 重复触发只计第一次。业务判定全在 Domain TremorGuard。
    private func tremorAccepted(careMode: Bool) -> Bool {
        let mode = careMode ? CareModeMetrics.care : CareModeMetrics.standard
        let accepted = TremorGuard.shouldAccept(lastActionAt: lastActionAt, now: Date(), mode: mode)
        if accepted { lastActionAt = Date() }
        else { logger.info("关怀模式防抖：忽略 0.3s 内重复点击") }
        return accepted
    }

    /// 计划创建（评审修正 P0：提醒链此前无用户起点——处方→计划 UI 缺失）
    func createPlan(patientId: UUID, medicationId: UUID, name: String, spec: String,
                    schedule: MedicationSchedule, startDate: Date) async throws {
        try await meds.createPlan(planId: UUID(), patientId: patientId, medicationId: medicationId,
                                  schedule: schedule, status: .active,
                                  startDate: startDate, endDate: nil)
        await refresh(patientId: patientId)
    }

    func createMedication(patientId: UUID, name: String, spec: String, unitKind: String) async throws -> UUID {
        let id = UUID()
        try await meds.createMedication(id: id, patientId: patientId, name: name, spec: spec, unitKind: unitKind)
        return id
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

    func completeAppointment(patientId: UUID, id: UUID) async {
        do {
            try await apts.complete(id: id)
            await refresh(patientId: patientId)
        } catch {
            logger.error("预约完成失败: \(error)")
        }
    }

    /// 首启通知授权（S1-3 修正：无授权时 UN 中心静默丢弃，生产提醒整体哑火）
    func requestNotificationAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            logger.error("通知授权请求失败: \(error)")
        }
    }
}
