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

    /// 触发型刷新的去抖锚点（评审修正）：启动/回前台/时区变化/各 Tab 的
    /// .task 在启动窗口内会叠加 2-4 次完整 refresh（每次含物化+对账+两次
    /// 系统 IPC）——触发型入口统一走 refreshTriggered 合并；动作型入口
    /// （确认/跳过/补录…）仍走 refresh，保证自己的写入即时可见。
    /// 第八轮全仓审查修复（冗余状态对收敛）：lastTriggerRefreshAt 与
    /// lastTriggerPatientId 只在 refreshTriggered 一处同时写入、同时读取——
    /// 恒同步运动的两个变量，任何单侧更新（如 force 路径只刷时间戳）都会
    /// 静默破坏成员维度去抖键（BR-001 隔离违例）。合并为单值对。
    private var lastTrigger: (at: Date, patientId: UUID?) = (.distantPast, nil)
    /// 在途守卫：refresh 链耗时可达秒级（30 日物化+对账+系统 IPC），
    /// 500ms 去抖挡不住「第一条还在跑、第二条又放行」的重复全量链。
    private var refreshInFlight = false

    init(meds: MedicationStore, apts: AppointmentStore, reconciler: ReminderReconciler,
         scheduler: any ReminderScheduling, composer: MedicationPlanComposer) {
        self.meds = meds
        self.apts = apts
        self.reconciler = reconciler
        self.scheduler = scheduler
        self.composer = composer
    }

    /// 触发型刷新入口（启动/回前台/时区变化/Tab 出现）：500ms 内合并为一次，
    /// 消除启动窗口内的重复全量对账与系统 IPC。now 参数注入保持测试确定性。
    /// 成员维度例外：换成员永远立即放行（BR-001 隔离，去抖不得吞新成员加载）。
    /// force 例外（评审修正第二轮）：时区显著变化（FR9.6 第 3 层）必须立即对账
    /// ——墙钟重锚拖到下次前台会让剂量通知在错误当地时间触发，去抖不得吞它。
    func refreshTriggered(patientId: UUID?, now: Date = Date(), force: Bool = false) async {
        // 第四轮全仓审查修复（5WHY）：成员维度例外必须先于在途/去抖守卫判定——
        // 原实现 refreshInFlight 守卫在最前，刷新在途时切换成员被整体丢弃，
        // 与注释「换成员永远立即放行（BR-001 隔离）」直接矛盾：旧刷新完成后
        // loadingPatientId==旧成员校验通过、把旧成员时段卡写入状态。成员变化
        // 与 force 同样绕过在途与去抖；并发写状态由 refresh 内
        // 「loadingPatientId == patientId」守卫兜底（只允许最新请求写回）。
        let isNewPatient = patientId != lastTrigger.patientId
        guard force || isNewPatient || !refreshInFlight else { return }
        guard force || isNewPatient || now.timeIntervalSince(lastTrigger.at) >= 0.5 else { return }
        lastTrigger = (now, patientId)
        refreshInFlight = true
        defer { refreshInFlight = false }
        await refresh(patientId: patientId, now: now)
    }

    /// FR14.5 语言切换：重写待投递通知的本地化文案（AppRootView 监听
    /// languageDidChange 调用；同 identifier add 即替换，fireAt 不变）
    func reloadLocalizedScheduledContent() async {
        do { try await scheduler.reloadLocalizedContent() }
        catch { logger.error("通知文案重写失败: \(error)") }
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
            // （第八轮修复：统一经 DayArithmetic 出口，禁裸 86400 兜底）
            let dayEnd = DayArithmetic.offset(days: 1, from: dayStart, calendar: cal)
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
            // 系统通知清单一次拉取、两个调度器共用——此前二者各自 pending()+
            // delivered()，每次 refresh 共 4 次全量系统 IPC + trigger 解析
            let pending = try await scheduler.pending()
            let delivered = try await scheduler.delivered()
            // FR9.11 批次到期三级提醒（幂等；FR13.10 备份提醒随 Phase 5 接入）
            await scheduleExpiryReminders(patientId: patientId, pending: pending, delivered: delivered)
            // FR9.8.3 分级续药通知（≤3 天 / 当日置顶）——审查修复：此前
            // 只有首页卡片，通知级触达全仓无调度点
            await scheduleRefillReminders(patientId: patientId, pending: pending, delivered: delivered)
        } catch {
            logger.error("提醒视图加载失败: \(error)")
        }
    }

    // MARK: - FR17.10 语音提醒设定 / FR8.10 观察随访提醒（通用 Reminder 语义）

    /// 语音提醒设定（FR17.10）：确认卡确认后经调度通道落「voice-rem-」通知。
    /// 删除/取消类指令在语音通道拒绝（F19 语义）；提醒只是触达不自动执行（BR-004）。
    /// 审查修复：repeatRule 生效（每天/每周X/工作日/周末，未知规则回落一次性）；
    /// 送达记录不再在调度时刻伪造「delivered」——BR-004 送达≠已服的事实链
    /// 只允许 outcome=NULL（仅 scheduled 行），delivered 由系统送达事实回写。
    func scheduleVoiceReminder(title: String, fireAt: Date, repeatRule: String?,
                               patientId: UUID) async {
        do {
            let notifyId = "voice-rem-\(UUID().uuidString)"
            try await scheduler.scheduleRepeating(dose: notifyId, at: fireAt,
                                                  route: .questionList, repeatRule: repeatRule)
            try await meds.recordDelivery(notifyId: notifyId, doseLogId: nil,
                                          channel: .local, outcome: nil, at: Date())
        } catch {
            logger.error("语音提醒调度失败: \(error)")
        }
    }

    /// FR8.10 观察随访提醒：保存后可设置「N 天后提醒对比/复查」。
    /// days 缺省 = Domain 规则默认（首访 3 天，此后每周——列表入口）；
    /// 详情页传入自定义天数（日历日推进，DST 安全）。到期生成首页待办；
    /// 锁屏不泄露观察类型词（BR-007 引申——文案走通用标题）。
    func scheduleObservationFollowUp(observationId: UUID, observedAt: Date,
                                     patientId: UUID,
                                     days: Int? = nil) async {
        do {
            let fireAt: Date
            if let days {
                fireAt = DayArithmetic.offset(days: days, from: Date())
            } else {
                fireAt = ObservationFollowUpRules.followUpDate(from: observedAt, occurrence: 0)
            }
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
            // 评审修正：与续药/到期提醒同纪律——送达后不再 pending，同 id 重排
            // = 每次启动 +1 小时无限重发；必须同时查已送达清单
            let delivered = try await scheduler.delivered()
            guard delivered.contains("backup-reminder") == false else { return }
            let fireAt = now.addingTimeInterval(3600)
            try await scheduler.schedule(dose: "backup-reminder", at: fireAt, route: .backupRestore)
        } catch {
            logger.error("备份提醒调度失败: \(error)")
        }
    }

    /// 评审修正第二轮：备份完成 → 清「backup-reminder 已送达」记录——
    /// 该记录是 FR13.10 周期提醒的「本周期已提醒」标记：不清理则送达一次后
    /// 永久一次性（30 天周期提醒在第 60/90 天静默消失）。AppRootView 在
    /// lastBackupAt 变化时调用，下一周期 needsReminder 重新放行。
    func clearBackupReminderDelivered() async {
        do { try await scheduler.removeDelivered(["backup-reminder"]) }
        catch { logger.error("备份提醒送达记录清理失败: \(error)") }
    }

    // MARK: - FR9.8.3 分级续药通知（≤3 天通知 / 当日置顶；≤7 天由首页卡承担）

    /// 为安全线余量进入 ≤3 天/当日档的活跃批次调度续药通知（"refill-" 前缀，
    /// 同 id 幂等）。触发时刻 = 剩余天数到达该档位的当天（当日档 = 余量归零日）。
    /// 零确认存活（FR9.8.8）：materializeMissed 已推进安全线，本调度与其共用
    /// 事实源；某档触发时 App 未运行 → 本次启动即时补发（5 分钟后），不静默吞掉。
    /// pending/delivered 由 refresh 一次性拉取传入（避免每次 refresh 4 次系统 IPC）。
    /// 已送达通知必须跳过：pending 守卫只管「尚未触发」——通知一旦送达便不再
    /// pending，每次 refresh（启动/回前台/时间变化）都以同一 id 重新调度，
    /// 形成「每次回前台 +5 分钟」的无限重发（FR9.8.3「同 id 幂等」只对送达前成立）。
    func scheduleRefillReminders(patientId: UUID, pending: [String: Date], delivered: Set<String>) async {
        do {
            let items = try await meds.inventorySummary(patientId: patientId, now: Date())
            var pending = pending
            let now = Date()
            for item in items {
                guard let tier = item.refillTier, let daysLeft = item.approxDaysLeft,
                      tier == .t3 || tier == .t0 else { continue }
                let thresholdDays = Int(tier.daysLeftThreshold)
                let computed = DayArithmetic.offset(days: max(0, daysLeft - thresholdDays), from: now)
                let fire = max(computed, now.addingTimeInterval(300))   // max(0,…) 已保证 computed ≥ now，直接取上界
                let notifyId = "refill-\(item.lotId.uuidString)-\(tier.rawValue)"
                guard pending[notifyId] == nil, !delivered.contains(notifyId) else { continue }
                try await scheduler.schedule(dose: notifyId, at: fire, route: .medicationCabinet)
                pending[notifyId] = fire
            }
        } catch {
            logger.error("续药提醒调度失败: \(error)")
        }
    }

    // MARK: - FR9.11 批次到期三级提醒（30/7/当日 → 到期即止，已过不补发）

    /// 为 30 天窗口内的活跃批次调度三级到期提醒（"exp-" 前缀，不受对账
    /// dose-/slot- 清理影响；同 id 幂等不重排）。点击路由 = 药箱页。
    /// pending/delivered 由 refresh 一次性拉取传入。
    /// 已送达的到期提醒必须跳过——否则送达后不再 pending，下次 refresh 以同一
    /// id 重排 + 重插 recordDelivery：同 id 违反 notification_delivery 主键，
    /// 异常中止整个 for 循环，其余批次静默失去到期提醒（FR9.11 链断），
    /// 且已送达提醒死而复生。
    func scheduleExpiryReminders(patientId: UUID, pending: [String: Date], delivered: Set<String>) async {
        do {
            let lots = try await meds.expiringLots(patientId: patientId, within: 30)
            var pending = pending
            for lot in lots {
                guard let expireAt = lot.expireAt else { continue }
                for (tier, fire) in BatchExpiryRules.fireDates(expireAt: expireAt, now: Date()) {
                    let notifyId = "exp-\(lot.lotId.uuidString)-\(tier.rawValue)"
                    guard pending[notifyId] == nil, !delivered.contains(notifyId) else { continue }
                    try await scheduler.schedule(dose: notifyId, at: fire, route: .medicationCabinet)
                    pending[notifyId] = fire
                    // FR9.18 送达记录：channel=local（通知权限由系统决定是否实际送达）；
                    // 审查修复：调度时刻不伪造 delivered（BR-004 事实链只记 scheduled）
                    try await meds.recordDelivery(notifyId: notifyId, doseLogId: nil,
                                                  channel: .local, outcome: nil, at: Date())
                }
            }
        } catch {
            logger.error("到期提醒调度失败: \(error)")
        }
    }

    /// 服药确认动作集（FR9.7）：动作按 notifyId UPDATE 物化行（评审修正 P0）。
    /// careMode=true 时经 TremorGuard 防抖——震颤模拟下连续重复点击只计一次
    /// （F18 关怀模式验收的落点；Domain 纯函数，本层只做门卫）。
    /// 返回是否确认成功——审查修复：原 Void 且内部吞错，代确认方无条件写
    /// 「由你代确认」审计（写失败的剂量被审计成已确认，事实链被污染）
    @discardableResult
    func confirmTaken(patientId: UUID, dose: ScheduledDose, careMode: Bool = false) async -> Bool {
        guard tremorAccepted(careMode: careMode) else { return false }
        do {
            try await meds.confirmTaken(notifyId: dose.notifyId, patientId: patientId)
            // 评审修正：清通知中心残留——已确认服用的剂量不得继续躺在锁屏
            // （BR-004 反向事实链：已服≠未送达）
            await removeDeliveredReminders(for: dose)
            await refresh(patientId: patientId)
            return true
        } catch {
            logger.error("确认服药失败: \(error)")
            return false
        }
    }

    /// FR9.17「全部已服用」批量动作（第六轮全仓审查修复）：单次震颤防抖
    /// 判定——一次按住确认 = 一个用户动作，不得被 0.3s 窗口逐条拦截
    /// （原实现视图层循环调 confirmTaken，关怀模式下只有第一条落库、
    /// 其余静默拒绝，卡片停在「1/3 已服」）。BR-004 语义不变：仍按单药
    /// 逐条写 dose_log；返回实际确认条数。
    func confirmSlotAllTaken(patientId: UUID, doses: [ScheduledDose],
                             careMode: Bool = false) async -> Int {
        guard tremorAccepted(careMode: careMode) else { return 0 }
        var confirmed = 0
        for dose in doses {
            do {
                try await meds.confirmTaken(notifyId: dose.notifyId, patientId: patientId)
                await removeDeliveredReminders(for: dose)
                confirmed += 1
            } catch {
                logger.error("批量确认服药失败: \(error)")
            }
        }
        if confirmed > 0 { await refresh(patientId: patientId) }
        return confirmed
    }

    func skipDose(dose: ScheduledDose, reason: String? = nil, careMode: Bool = false,
                  patientId: UUID? = nil) async {
        guard tremorAccepted(careMode: careMode) else { return }
        do {
            try await meds.recordAction(notifyId: dose.notifyId, action: .skipped, reason: reason)
            // 审查修复：动作后刷新今日时段缓存——原实现跳过/忘记/不适不刷新，
            // 时段卡继续显示「待确认」直到下次对账触发（与 confirmTaken 对齐）
            await removeDeliveredReminders(for: dose)
            if let patientId { await refresh(patientId: patientId) }
        } catch {
            logger.error("跳过记录失败: \(error)")
        }
    }

    /// 移除该剂量的已送达通知（dose- 本体与所属时段 slot-）
    private func removeDeliveredReminders(for dose: ScheduledDose) async {
        let ids = [dose.notifyId, await slotNotifyId(for: dose)].compactMap { $0 }
        do { try await scheduler.removeDelivered(ids) }
        catch { logger.error("已送达通知清理失败: \(error)") }
    }

    /// 第七轮全仓审查修复：合并时段（≤30min 双剂）内非锚剂量的单剂派生
    /// slot id 与排程时段的合并 id 分叉——清理/取消命中不存在的 id，
    /// 已送达的时段通知残留锁屏（BR-004 反向事实链）。今日时段卡已持有
    /// 聚合结果，直接按剂量反查真实时段 id。
    /// 第八轮修复：非今日持有路径（跨成员代确认/冷启动横幅/历史日剂量）
    /// 的单剂派生回落在合并时段同样分叉——改为按该剂量所在日全量记录
    /// 分组反查（与对账引擎同一 id 来源）；查询失败才退回单剂派生
    /// （单剂时段二者一致，语义安全；清理尽力而为）。
    private func slotNotifyId(for dose: ScheduledDose) async -> String? {
        if let slot = todaySlots.first(where: { $0.records.contains { $0.id == dose.notifyId } }) {
            return "slot-\(slot.id)"
        }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: dose.dueAt)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        if let facts = try? await meds.deliveryFacts(from: dayStart, to: dayEnd) {   // try?-ok: 反查失败退回单剂派生（清理尽力而为，绝不阻断确认主流程）
            let records = facts.map { DoseRecord(dose: $0.dose, action: $0.action) }
            if let slotId = DoseSlotGrouping.slotIds(records)[dose.notifyId] {
                return "slot-\(slotId)"
            }
        }
        return DoseSlotGrouping.slotId(for: DoseRecord(dose: dose)).map { "slot-\($0)" }
    }

    /// FR9.5 忘记服用（显式记录，与超时自动 missed 区分——BR-004 送达≠已服）
    func forgetDose(dose: ScheduledDose, careMode: Bool = false,
                    patientId: UUID? = nil) async {
        guard tremorAccepted(careMode: careMode) else { return }
        do {
            try await meds.recordAction(notifyId: dose.notifyId, action: .missed)
            if let patientId { await refresh(patientId: patientId) }
        } catch {
            logger.error("忘记记录失败: \(error)")
        }
    }

    /// FR9.5 记录不适（discomfort 按扣减矩阵两线各 −1）
    func recordDiscomfort(dose: ScheduledDose, note: String?, careMode: Bool = false,
                          patientId: UUID? = nil) async {
        guard tremorAccepted(careMode: careMode) else { return }
        do {
            try await meds.recordAction(notifyId: dose.notifyId, action: .discomfort, reason: note)
            if let patientId { await refresh(patientId: patientId) }
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
            // 第七轮修复：时段 id 经聚合结果反查（slotNotifyId），
            // 合并时段内非锚剂量不再取消到不存在的 id
            await reconciler.snooze(doseNotifyId: dose.notifyId, slotNotifyId: await slotNotifyId(for: dose),
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
    /// doseUnits（评审修正 D1）：每剂剂量落 dose_plan_units（安全线单剂基线，
    /// data-flow-spec line 463）——此前表单收集的剂量被静默丢弃、物化行恒为 1.0。
    func createPlan(patientId: UUID, medicationId: UUID, name: String, spec: String,
                    schedule: MedicationSchedule, startDate: Date,
                    doseUnits: Double = 1) async throws {
        try await meds.createPlan(planId: UUID(), patientId: patientId, medicationId: medicationId,
                                  schedule: schedule, status: .active,
                                  startDate: startDate, endDate: nil,
                                  doseUnits: doseUnits)
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

    func pausePlan(planId: UUID, patientId: UUID? = nil) async {
        do {
            try await composer.pausePlan(planId: planId)
            // 审查修复：暂停/恢复/结束后立即对账——原实现只翻状态行，
            // 已排的剂量通知要等到下次启动/回前台才被对账清理，
            // 暂停的计划继续按时弹提醒（用户以为暂停失败）
            if let patientId { await refresh(patientId: patientId) }
            else { await reconciler.reconcile(now: Date()) }
        }
        catch { logger.error("暂停计划失败: \(error)") }
    }

    func resumePlan(planId: UUID, patientId: UUID? = nil) async {
        do {
            try await composer.resumePlan(planId: planId)
            if let patientId { await refresh(patientId: patientId) }
            else { await reconciler.reconcile(now: Date()) }
        }
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
                           startsAt: Date, doctor: String? = nil, address: String? = nil,
                           itemsToBring: String? = nil, notes: String? = nil,
                           followUpRule: Int? = nil, followUpDays: Int? = nil) async {
        do {
            let aptId = try await apts.create(patientId: patientId, hospital: hospital,
                                              department: department, startsAt: startsAt,
                                              doctor: doctor, address: address,
                                              itemsToBring: itemsToBring, notes: notes,
                                              now: Date())
            // FR10.2 复诊规则：规则 1（N 天后）/4（慢病定期随访 N 天）落具体
            // 日期 → 排复诊提醒（此前表单收集的复诊配置被静默丢弃）
            if let rule = followUpRule, rule == 1 || rule == 4,
               let days = followUpDays, days > 0 {
                let cal = Calendar.current
                let followUpAt = cal.date(byAdding: .day, value: days, to: startsAt) ?? startsAt
                try await scheduler.schedule(dose: "followup-apt-\(aptId.uuidString)",
                                             at: followUpAt, route: .appointmentDetail(aptId))
            }
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
