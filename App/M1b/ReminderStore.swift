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
    /// FR9.11 批次到期三级 / FR13.10 备份提醒的调度通道（与对账同一 ReminderScheduling）
    private let scheduler: any ReminderScheduling
    /// FR9.15/§4.2 计划生命周期与五表原子创建（处方→计划参考模板）
    private let composer: MedicationPlanComposer
    private let logger = Logger(subsystem: "com.vitaliber", category: "reminders")
    /// 关怀模式震颤防抖（F18）：同一动作按钮的最近一次触发时刻；
    /// 连续重复点击在防抖窗口内只计一次（TremorGuard 是 Domain 纯函数）
    private var lastActionAt: Date?

    /// 最近一次请求的成员（BR-001 成员隔离：只允许最新请求写回状态）
    private var loadingPatientId: UUID?

    init(meds: MedicationStore, apts: AppointmentStore, reconciler: ReminderReconciler,
         scheduler: any ReminderScheduling, composer: MedicationPlanComposer) {
        self.meds = meds
        self.apts = apts
        self.reconciler = reconciler
        self.scheduler = scheduler
        self.composer = composer
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
            // BR-001 成员隔离：facts 为全量事实（对账引擎消费），UI 时段卡
            // 必须过滤到当前成员——否则 A 成员剂量会混进 B 成员今日待办
            let mine = facts.filter { $0.patientId == nil || $0.patientId == patientId }
            let records = mine.map { DoseRecord(dose: $0.dose, action: $0.action) }
            let slots = DoseSlotGrouping.group(records)
            let appointments = try await apts.upcoming(patientId: patientId, now: now)
            // 成员切换后晚到的旧结果必须丢弃，不得覆盖当前成员（BR-001）
            guard loadingPatientId == patientId else { return }
            todaySlots = slots
            upcomingAppointments = appointments
            // FR9.11 批次到期三级提醒（幂等；FR13.10 备份提醒随 Phase 5 接入）
            await scheduleExpiryReminders(patientId: patientId)
        } catch {
            logger.error("提醒视图加载失败: \(error)")
        }
    }

    // MARK: - FR17.10 语音提醒设定 / FR8.10 观察随访提醒（通用 Reminder 语义）

    /// 语音提醒设定（FR17.10）：确认卡确认后经调度通道落「voice-rem-」通知。
    /// 删除/取消类指令在语音通道拒绝（F19 语义）；提醒只是触达不自动执行（BR-004）。
    func scheduleVoiceReminder(title: String, fireAt: Date, repeatRule: String?,
                               patientId: UUID) async {
        do {
            let notifyId = "voice-rem-\(UUID().uuidString)"
            try await scheduler.schedule(dose: notifyId, at: fireAt, route: .questionList)
            try await meds.recordDelivery(notifyId: notifyId, doseLogId: nil,
                                          channel: .local, outcome: "delivered", at: Date())
        } catch {
            logger.error("语音提醒调度失败: \(error)")
        }
    }

    /// FR8.10 观察随访提醒：保存后可设置「N 天后提醒对比/复查」（默认 3 天）。
    /// 到期生成首页待办；锁屏不泄露观察类型词（BR-007 引申——文案走通用标题）。
    func scheduleObservationFollowUp(observationId: UUID, observedAt: Date,
                                     patientId: UUID) async {
        do {
            let fireAt = ObservationFollowUpRules.followUpDate(from: observedAt, occurrence: 0)
            let notifyId = "followup-\(observationId.uuidString)"
            try await scheduler.schedule(dose: notifyId, at: fireAt, route: .observationDetail(observationId))
        } catch {
            logger.error("随访提醒调度失败: \(error)")
        }
    }

    // MARK: - FR13.10 定期备份提醒（默认 30 天；只引导到导出向导，不自动创建备份文件）

    /// 距上次备份超过间隔 → 调度一次备份提醒（"backup-" 前缀，幂等；
    /// 路由 = 备份恢复页）。提醒只引导，绝不自动创建备份文件（FR13.10）。
    func scheduleBackupReminderIfNeeded(lastBackupAt: TimeInterval?, now: Date = Date()) async {
        guard BackupReminderRules.needsReminder(
            lastBackupAt: lastBackupAt.map { Date(timeIntervalSince1970: $0) }, now: now) else { return }
        do {
            let pending = try await scheduler.pending()
            guard pending.keys.contains("backup-reminder") == false else { return }
            let fireAt = now.addingTimeInterval(3600)
            try await scheduler.schedule(dose: "backup-reminder", at: fireAt, route: .backupRestore)
        } catch {
            logger.error("备份提醒调度失败: \(error)")
        }
    }

    // MARK: - FR9.11 批次到期三级提醒（30/7/3 天 → 到期即止，不补发）

    /// 为 30 天窗口内的活跃批次调度三级到期提醒（"exp-" 前缀，不受对账
    /// dose-/slot- 清理影响；同 id 幂等不重排）。点击路由 = 药箱页。
    func scheduleExpiryReminders(patientId: UUID) async {
        do {
            let lots = try await meds.expiringLots(patientId: patientId, within: 30)
            var pending = try await scheduler.pending()
            for lot in lots {
                guard let expireAt = lot.expireAt else { continue }
                for (tier, fire) in BatchExpiryRules.fireDates(expireAt: expireAt, now: Date()) {
                    let notifyId = "exp-\(lot.lotId.uuidString)-\(tier.rawValue)"
                    guard pending[notifyId] == nil else { continue }
                    try await scheduler.schedule(dose: notifyId, at: fire, route: .medicationCabinet)
                    pending[notifyId] = fire
                    // FR9.18 送达记录：channel=local（通知权限由系统决定是否实际送达）
                    try await meds.recordDelivery(notifyId: notifyId, doseLogId: nil,
                                                  channel: .local, outcome: "delivered", at: Date())
                }
            }
        } catch {
            logger.error("到期提醒调度失败: \(error)")
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

    func skipDose(dose: ScheduledDose, reason: String? = nil, careMode: Bool = false) async {
        guard tremorAccepted(careMode: careMode) else { return }
        do {
            try await meds.recordAction(notifyId: dose.notifyId, action: .skipped, reason: reason)
        } catch {
            logger.error("跳过记录失败: \(error)")
        }
    }

    /// FR9.5 忘记服用（显式记录，与超时自动 missed 区分——BR-004 送达≠已服）
    func forgetDose(dose: ScheduledDose, careMode: Bool = false) async {
        guard tremorAccepted(careMode: careMode) else { return }
        do {
            try await meds.recordAction(notifyId: dose.notifyId, action: .missed)
        } catch {
            logger.error("忘记记录失败: \(error)")
        }
    }

    /// FR9.5 记录不适（discomfort 按扣减矩阵两线各 −1）
    func recordDiscomfort(dose: ScheduledDose, note: String?, careMode: Bool = false) async {
        guard tremorAccepted(careMode: careMode) else { return }
        do {
            try await meds.recordAction(notifyId: dose.notifyId, action: .discomfort, reason: note)
        } catch {
            logger.error("不适记录失败: \(error)")
        }
    }

    /// FR9.16 补录/追溯服药：落在实际发生时间，双轨各 −1，如实记录不美化
    func backfillTaken(planId: UUID, patientId: UUID, medicationId: UUID,
                       actualTime: Date, doseUnits: Double) async {
        do {
            try await meds.recordTakenAt(planId: planId, patientId: patientId,
                                         medicationId: medicationId,
                                         actualTime: actualTime, doseUnits: doseUnits)
            await refresh(patientId: patientId)
        } catch {
            logger.error("补录失败: \(error)")
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

    /// 计划创建（评审修正 P0：提醒链此前无用户起点——处方→计划 UI 缺失）。
    /// FR20.2 价值先行：完成第一个提醒计划创建后才请求通知授权（严禁启动即索权）。
    func createPlan(patientId: UUID, medicationId: UUID, name: String, spec: String,
                    schedule: MedicationSchedule, startDate: Date) async throws {
        try await meds.createPlan(planId: UUID(), patientId: patientId, medicationId: medicationId,
                                  schedule: schedule, status: .active,
                                  startDate: startDate, endDate: nil)
        await requestNotificationAuthorization()
        await refresh(patientId: patientId)
    }

    func createMedication(patientId: UUID, name: String, spec: String, unitKind: String) async throws -> UUID {
        let id = UUID()
        try await meds.createMedication(id: id, patientId: patientId, name: name, spec: spec, unitKind: unitKind)
        return id
    }

    // MARK: - FR9.15 计划生命周期 + FR9.16 查询投影（SP-15 详情页数据源）

    /// 成员全部计划（列表）
    func plans(patientId: UUID) async throws -> [MedicationStore.PlanRow] {
        try await meds.plans(patientId: patientId)
    }

    func plan(id: UUID) async throws -> MedicationStore.PlanRow? {
        try await meds.plan(id: id)
    }

    /// FR9.16 日程条数据（本周七日格）
    func doseLog(planId: UUID, from: Date, to: Date) async throws -> [MedicationStore.DoseLogRow] {
        try await meds.doseLog(planId: planId, from: from, to: to)
    }

    /// FR9.15 计划历史时间轴
    func lifecycleEvents(planId: UUID) async throws -> [PlanLifecycleEvent] {
        try await composer.lifecycleEvents(planId: planId)
    }

    /// FR9.9 药品知识卡：医嘱原文（来源徽章 A/C）
    func medicationAdvice(medicationId: UUID) async throws -> String? {
        try await meds.adviceForMedication(medicationId: medicationId)
    }

    func pausePlan(planId: UUID) async {
        do { try await composer.pausePlan(planId: planId) }
        catch { logger.error("暂停计划失败: \(error)") }
    }

    func resumePlan(planId: UUID) async {
        do { try await composer.resumePlan(planId: planId) }
        catch { logger.error("恢复计划失败: \(error)") }
    }

    func endPlan(planId: UUID, reason: PlanEndReason, patientId: UUID) async {
        do {
            try await composer.endPlan(planId: planId, reason: reason)
            // 审查修复：原 loadingPatientId ?? UUID()——loading 为 nil 时以随机
            // UUID 刷新，事实过滤后今日时段被清空（用户看到空列表）且污染
            // loadingPatientId（BR-001 锚点语义破坏）。显式携带 patientId。
            await refresh(patientId: patientId)
        } catch {
            logger.error("结束计划失败: \(error)")
        }
    }

    func editPlanSchedule(planId: UUID, schedule: MedicationSchedule) async {
        do { try await composer.editPlanSchedule(planId: planId, schedule: schedule) }
        catch { logger.error("编辑计划失败: \(error)") }
    }

    /// FR9.1-9.3 处方→计划五表原子创建（§4.2 参考模板；BR-003 未确认拒绝）
    func createPlanFromPrescription(prescription: Prescription,
                                    plan: MedicationPlanDraft,
                                    initialLot: StockLotDraft) async throws {
        _ = try await composer.createMedicationPlan(prescription: prescription,
                                                    plan: plan, initialLot: initialLot)
    }

    func createAppointment(patientId: UUID, hospital: String, department: String,
                           startsAt: Date) async {
        do {
            try await apts.create(patientId: patientId, hospital: hospital,
                                  department: department, startsAt: startsAt, now: Date())
            await requestNotificationAuthorization()   // FR20.2 价值先行（首个提醒创建后）
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

    /// FR10.7：标记错过（触发跟进提醒）
    func markAppointmentMissed(patientId: UUID, id: UUID) async {
        do {
            try await apts.markMissed(id: id)
            await refresh(patientId: patientId)
        } catch {
            logger.error("预约错过标记失败: \(error)")
        }
    }

    /// FR10.7：取消（选填原因）
    func cancelAppointment(patientId: UUID, id: UUID, reason: String?) async {
        do {
            try await apts.cancel(id: id, reason: reason)
            await refresh(patientId: patientId)
        } catch {
            logger.error("预约取消失败: \(error)")
        }
    }

    /// FR10.7：改期（原预约保留历史 + 新草稿）
    func rescheduleAppointment(patientId: UUID, id: UUID, to startsAt: Date) async {
        do {
            _ = try await apts.reschedule(id: id, startsAt: startsAt)
            await refresh(patientId: patientId)
        } catch {
            logger.error("预约改期失败: \(error)")
        }
    }

    /// SP-18 状态机历史（四态分段列表）
    func appointmentHistory(patientId: UUID) async -> [AppointmentRow] {
        (try? await apts.history(patientId: patientId)) ?? []   // try?-ok: 读取失败=空列表降级
    }

    /// FR24.5 家庭待确认剂量（跨成员聚合；每行携带成员，代确认落回该成员）
    func familyPendingDoses(from: Date, to: Date) async throws -> [FamilyPendingDose] {
        try await meds.familyPendingDoses(from: from, to: to)
    }

    /// FR20.2 通知授权（价值先行）：仅在首个提醒计划/预约创建后调用；
    /// 启动路径禁止调用（严禁启动即索权）。
    func requestNotificationAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            logger.error("通知授权请求失败: \(error)")
        }
    }

    /// FR9.6/FR20.2：通知权限是否已被拒绝（拒绝后首页常驻提示条，可关、次日重现）。
    /// 拒绝态由系统设置决定，本方法只读不弹框。
    var notificationDenied: Bool {
        get async {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return settings.authorizationStatus == .denied
        }
    }
}
