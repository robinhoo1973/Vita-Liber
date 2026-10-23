import SwiftUI
import Domain
import Infrastructure
import Perception

/// 提醒模块（SP 系列 M1b 切片）：今日时段聚合卡 + 服药三选动作 + 预约列表。
/// 动效只表达状态迁移（ui-ux §1 原则 6）；敏感内容默认不展开。
struct RemindersView: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminders
    @State private var showNewAppointment = false
    /// 审查修复（响亮失败纪律）：预约创建失败可见告警——此前 createAppointment
    /// 吞错、sheet 无条件关闭，创建失败呈现为成功（预约与分级提醒实际不存在）
    @State private var appointmentSaveFailed = false

    var body: some View {
        WithPerceptionTracking {
            List {
                Section(L10n.reminder_today) {
                    if reminders.todaySlots.isEmpty {
                        Text(reminders.loading ? L10n.reminder_loading : L10n.reminder_todayEmpty)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("SP-09.today.empty")
                    }
                    ForEach(reminders.todaySlots) { slot in
                        // ForEach 行闭包逃逸：行内同步读感知对象属性，须自行包裹（子项目 I）
                        WithPerceptionTracking {
                            DoseSlotCard(
                                slot: slot,
                                onTaken: { dose in
                                    Task { await reminders.confirmTaken(patientId: currentPatientId, dose: dose, careMode: app.careMode) }
                                },
                                onSkip: { dose, reason in
                                    Task { await reminders.skipDose(dose: dose, reason: reason, careMode: app.careMode, patientId: currentPatientId) }
                                },
                                onSnooze: { dose, minutes in
                                    Task { await reminders.snoozeDose(dose: dose, minutes: minutes, patientId: currentPatientId, careMode: app.careMode) }
                                },
                                onForget: { dose in
                                    Task { await reminders.forgetDose(dose: dose, careMode: app.careMode, patientId: currentPatientId) }
                                },
                                onDiscomfort: { dose, note in
                                    Task { await reminders.recordDiscomfort(dose: dose, note: note, careMode: app.careMode, patientId: currentPatientId) }
                                },
                                onSlotAllTaken: {
                                    // FR9.17「全部已服用」= 逐药写 taken（底层仍按单药 dose_log）；
                                    // 防抖只判一次（批量动作单闸门——关怀模式循环逐条
                                    // confirmTaken 会被 0.3s 震颤窗拦下除第一条外的全部）
                                    let pending = slot.records.filter { $0.isUnresolved }.map(\.dose)
                                    Task { await reminders.confirmSlotAllTaken(patientId: currentPatientId, doses: pending, careMode: app.careMode) }
                                },
                                careMode: app.careMode)
                        }
                    }
                    // FR9.15/SP-15 计划列表入口（生命周期管理）
                    NavigationLink {
                        MedicationPlanListView()
                    } label: {
                        Label(L10n.planListTitle, systemImage: "list.bullet.clipboard")
                    }
                    .accessibilityIdentifier("SP-15.plan.list")
                    // 2026-10-24 业主：不再有独立的「添加用药计划」表单；
                    // 「新建用药计划」页（时段模板）取代之。
                    NavigationLink {
                        MedicationScheduleFormRouteView(templateId: nil)
                    } label: {
                        Label(L10n.reminder_planNew, systemImage: "plus")
                    }
                    .accessibilityIdentifier("SP-09.plan.add")
                }
                Section(L10n.reminder_appointments) {
                    if reminders.upcomingAppointments.isEmpty {
                        Text(L10n.reminder_emptyAppt)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("SP-18.appointment.empty")
                    }
                    ForEach(reminders.upcomingAppointments, id: \.id) { apt in
                        // §3.4 单一出口：预约 = `calendar.badge.clock`（原硬编码 `stethoscope`
                        // 是**就诊**符号——预约行显示就诊符号，类别不可辨）。
                        let appointmentIcon = CardKindIcon.spec(timelineKind: .appointment)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                // §11-13 设计系统规则：行内小尺寸用 SF Symbols，瓷砖仅供大尺寸场景。
                                Image(systemName: appointmentIcon.symbol)
                                    .font(.title3)
                                    .foregroundStyle(appointmentIcon.tint)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(apt.hospital).font(.headline)
                                    Text("\(apt.department) · \(apt.startsAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(statusLabel(apt.status))
                                    .font(.caption2)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(statusColor(apt.status).opacity(0.15)))
                                    .foregroundStyle(statusColor(apt.status))
                                // 审查修复（FR10.7 时间门槛）：未到开始时间的
                                // 预约不呈现完成按钮——此前一触即完成（分级
                                // 提醒全取消 + 未来日期「复诊」就诊落库，
                                // BR-004 历史造假），AppointmentListView 已修、
                                // 本 Tab 入口漏修（AppointmentStore.complete
                                // 另加纵深防御）。
                                if AppointmentRules.canMarkCompleted(startsAt: apt.startsAt) {
                                    Button {
                                        Task { await reminders.completeAppointment(patientId: currentPatientId, id: apt.id) }
                                    } label: {
                                        Image(systemName: "checkmark.circle")
                                            .frame(width: 44, height: 44)
                                    }
                                    .accessibilityLabel(L10n.reminder_completeAppt)
                                    .accessibilityIdentifier("SP-18.appointment.complete")
                                }
                            }
                            // FR10.6 去挂号深链卡：本地映射表匹配，无网可用
                            AppointmentDeepLinkCard(hospital: apt.hospital)
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("SP-18.appointment.row")
                    }
                    Button {
                        showNewAppointment = true
                    } label: {
                        Label(L10n.reminder_addAppt, systemImage: "plus")
                    }
                    .accessibilityIdentifier("SP-18.appointment.add")
                }
                // FR24.5 同机照护者视图入口
                Section {
                    NavigationLink {
                        CaregiverViews()
                    } label: {
                        Label(L10n.caregiverTitle, systemImage: "person.2.fill")
                    }
                    .accessibilityIdentifier("FR24.5.entry")
                }
            }
            .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
            // 2026-10-04 业主反馈（tab 页顶部留空过大）：同 HomeView 先例
            .contentMarginsCompat(.top, 0, for: .scrollContent)
            .listSectionSpacingCompat(.compact)
            .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
            .navigationTitle(L10n.navReminders)
            .navigationBarTitleDisplayMode(.inline)   // 2026-10-04 业主反馈：tab 根统一 inline（同 HomeView 先例）
            .task(id: currentPatientId) {
                await reminders.refreshTriggered(patientId: currentPatientId)
            }
            .sheet(isPresented: $showNewAppointment) {
                NewAppointmentSheet { hospital, department, date in
                    Task {
                        let ok = await reminders.createAppointment(patientId: currentPatientId,
                                                                   hospital: hospital, department: department,
                                                                   startsAt: date)
                        if ok { showNewAppointment = false } else { appointmentSaveFailed = true }
                    }
                }
            }
            .alert(L10n.reminder_apptSaveFailed, isPresented: $appointmentSaveFailed) {
                Button(L10n.commonConfirm, role: .cancel) { }
            }
        }
    }

    private var currentPatientId: UUID { app.currentPatientId }

    private func statusLabel(_ s: String) -> String {
        switch s {
        case "scheduled": return L10n.reminder_statusScheduled
        case "completed": return L10n.reminder_statusCompleted
        case "cancelled": return L10n.reminder_statusCancelled
        case "missed": return L10n.reminder_statusMissed
        default: return s
        }
    }
    private func statusColor(_ s: String) -> Color {
        switch s {
        case "scheduled": return Color("brand-primary", bundle: .main)
        case "completed": return Color("semantic-success", bundle: .main)
        case "cancelled", "missed": return Color("text-secondary", bundle: .main)
        default: return .secondary
        }
    }
}


/// 时段卡（评审修正批 + FR9.5/FR9.17 全量）：
/// - 药名/规格可区分、≥44pt 触点、逐钮带药名的无障碍标签；
/// - 动作集（FR9.5）：已服用 / 稍后（15/30/1h 自选）/ 跳过（必选原因）/
///   忘记服用 / 记录不适；
/// - 时段级（FR9.17）：n/N 进度 + [全部已服用] 按住确认（关怀模式防误触，
///   规则在 Domain HoldToConfirm），底层仍按单药 dose_log 记录。
struct DoseSlotCard: View {
    let slot: DoseSlot
    let onTaken: (ScheduledDose) -> Void
    let onSkip: (ScheduledDose, String) -> Void
    let onSnooze: (ScheduledDose, Int) -> Void
    let onForget: (ScheduledDose) -> Void
    let onDiscomfort: (ScheduledDose, String?) -> Void
    let onSlotAllTaken: () -> Void
    let careMode: Bool

    @State private var skipCandidate: ScheduledDose?
    @State private var discomfortCandidate: ScheduledDose?
    @State private var discomfortNote = ""
    @State private var allTakenHoldConfirmed = false

    /// 部分确认态如实显示（FR9.17：已服 n/N）
    private var takenCount: Int {
        slot.records.filter { $0.action == .taken || $0.action == .discomfort }.count
    }

    /// S-1（第九轮审查 U1#2/U2#3，FR18.2/§5.57）：careMode 参数此前声明后**从未
    /// 读取**——关怀模式在该首要服药确认卡上仍为 44pt/8pt 间距。触点与行间距
    /// 统一取 Domain CareModeMetrics（常规 44/8、关怀 64/16）。
    private var metrics: CareModeMetrics { careMode ? .care : .standard }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(slot.anchorTime.formatted(date: .omitted, time: .shortened))
                        .font(.headline)
                    // n/N 进度（部分确认如实显示，如 1/3）
                    Text(L10n.reminderTakenCount(takenCount, slot.records.count))
                        .font(.footnote)
                        .foregroundStyle(slot.allTaken
                                         ? Color("semantic-success", bundle: .main) : .secondary)
                    Spacer()
                    // 时段级 [全部已服用]：只在有未决剂量时出现（FR9.17）
                    if !slot.allTaken && slot.records.count > 1 {
                        if careMode {
                            // S-1：关怀模式改按住确认（≥600ms 环形进度 + 完成触觉，
                            // HoldToConfirmRing 与 SOSOrb 同源）——震颤下两连点
                            // （轻点→再点确认）极易误触把未服剂量整体记成已服。
                            HoldToConfirmRing(requiredSeconds: HoldToConfirm.requiredSeconds(mode: .care),
                                              maxTravel: CareModeMetrics.care.sosOrbMaxTravelPoints,
                                              cornerRadius: VLCornerRadius.compact,
                                              ringColor: Color("brand-primary", bundle: .main)) {
                                Text(L10n.reminder_allTaken)
                                    .font(.footnote)
                                    .frame(minHeight: metrics.touchTarget)
                                    .padding(.horizontal, 10)
                            } onComplete: {
                                onSlotAllTaken()
                            }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(L10n.reminder_allTaken)
                            .accessibilityAction { onSlotAllTaken() }
                            .accessibilityIdentifier("SP-09.doseSlot.allTaken")
                        } else if allTakenHoldConfirmed {
                            Text(L10n.reminder_allTakenConfirm)
                                .font(.caption).foregroundStyle(Color("semantic-warning", bundle: .main))
                            Button(L10n.reminder_allTakenYes) { onSlotAllTaken() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                    .frame(minHeight: metrics.touchTarget)   // 触点（S-1：关怀 64pt）
                                .accessibilityIdentifier("SP-09.doseSlot.allTaken.confirm")
                            Button(L10n.commonCancel) { allTakenHoldConfirmed = false }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                    .frame(minHeight: metrics.touchTarget)   // 触点（S-1：关怀 64pt）
                        } else {
                            Button {
                                allTakenHoldConfirmed = true
                            } label: {
                                Text(L10n.reminder_allTaken)
                                    .font(.footnote)
                                    .frame(minHeight: metrics.touchTarget)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("SP-09.doseSlot.allTaken")
                        }
                    }
                }
                ForEach(slot.records, id: \DoseRecord.dose.notifyId) { record in
                    HStack(spacing: metrics.spacing) {   // S-1：关怀 16pt
                        Text(record.displayLabel)          // 「药名 规格 · 剂量 单位」（评审阻断项修正）
                            .font(.subheadline)
                            .monospacedDigit()
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if record.action == .taken {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color("semantic-success", bundle: .main))
                                .frame(width: metrics.touchTarget, height: metrics.touchTarget)   // S-1
                        } else if let action = record.action, action == .skipped || action == .discomfort {
                            // 跳过/不适 = 展示型决议（不动按钮）
                            Text(actionShortLabel(action))
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(minWidth: metrics.touchTarget, minHeight: metrics.touchTarget)   // S-1
                        } else if record.action == .missed {
                            // 业主裁决 D5：missed 行只给「已服」确认（转场扣减只补确认轨）——
                            // 稍后/跳过/忘记/不适仍是 Store 层已决议守卫的禁用转换，
                            // 不得露按钮（否则静默 no-op + 稍后误武装提醒）。
                            Button {
                                onTaken(record.dose)
                            } label: {
                                Text(L10n.reminder_taken).frame(minWidth: max(64, metrics.touchTarget), minHeight: metrics.touchTarget)   // S-1
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel(L10n.reminder_a11yTaken(name: record.medicationName ?? L10n.reminder_medicationFallback))
                            .accessibilityIdentifier("SP-09.dose.taken")
                        } else {
                            // ≥44pt 横排：已服用（主）+ 稍后 Menu + 更多动作 Menu（FR9.5 全动作集）
                            Button {
                                onTaken(record.dose)
                            } label: {
                                Text(L10n.reminder_taken).frame(minWidth: max(64, metrics.touchTarget), minHeight: metrics.touchTarget)   // S-1
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel(L10n.reminder_a11yTaken(name: record.medicationName ?? L10n.reminder_medicationFallback))
                            .accessibilityIdentifier("SP-09.dose.taken")
                            Menu {
                                Button(L10n.reminder_snooze15) { onSnooze(record.dose, 15) }
                                Button(L10n.reminder_snooze30) { onSnooze(record.dose, 30) }
                                Button(L10n.reminder_snooze60) { onSnooze(record.dose, 60) }
                            } label: {
                                Text(L10n.reminder_later).frame(minWidth: max(52, metrics.touchTarget), minHeight: metrics.touchTarget)   // S-1
                            }
                            .accessibilityIdentifier("SP-09.dose.snooze")
                            Menu {
                                Button(L10n.reminder_skip) { skipCandidate = record.dose }
                                Button(L10n.reminder_forgot) { onForget(record.dose) }
                                Button(L10n.reminder_discomfort) { discomfortCandidate = record.dose }
                            } label: {
                                Image(systemName: "ellipsis").frame(minWidth: metrics.touchTarget, minHeight: metrics.touchTarget)   // S-1
                            }
                            .accessibilityLabel(L10n.reminder_moreActions)
                            .accessibilityIdentifier("SP-09.dose.more")
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .opacity(slot.allTaken ? 0.55 : 1.0)          // ui-ux §4.21：全部已服整卡降透明度
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SP-09.doseSlot.card")
            // FR9.5 跳过必选原因（可免填备注）
            .confirmationDialog(L10n.reminder_skip, isPresented: skipBinding, titleVisibility: .visible) {
                Button(L10n.reminder_skipReasonNone) { submitSkip(nil) }
                Button(L10n.reminder_skipReasonForgot) { submitSkip("forgot") }
                Button(L10n.reminder_skipReasonDoctor) { submitSkip("doctor_adjusted") }
                Button(L10n.reminder_skipReasonOther) { submitSkip("other") }
                Button(L10n.commonCancel, role: .cancel) { skipCandidate = nil }
            }
            // FR9.5 记录不适（备注可免填）
            .alert(L10n.reminder_discomfort, isPresented: discomfortBinding) {
                TextField(L10n.reminder_discomfortPlaceholder, text: $discomfortNote)
                Button(L10n.reminder_save) {
                    if let dose = discomfortCandidate {
                        onDiscomfort(dose, discomfortNote.isEmpty ? nil : discomfortNote)
                    }
                    discomfortNote = ""
                    discomfortCandidate = nil
                }
                Button(L10n.commonCancel, role: .cancel) {
                    discomfortNote = ""
                    discomfortCandidate = nil
                }
            }
        }
    }

    private var skipBinding: Binding<Bool> {
        Binding(get: { skipCandidate != nil }, set: { if !$0 { skipCandidate = nil } })
    }
    private var discomfortBinding: Binding<Bool> {
        Binding(get: { discomfortCandidate != nil }, set: { if !$0 { discomfortCandidate = nil } })
    }

    private func submitSkip(_ reason: String?) {
        if let dose = skipCandidate {
            onSkip(dose, reason ?? "skip")
        }
        skipCandidate = nil
    }

    private func actionShortLabel(_ action: DoseUserAction?) -> String {
        switch action {
        case .skipped: return L10n.reminder_skip
        case .missed: return L10n.reminder_forgot
        case .discomfort: return L10n.reminder_discomfort
        case .snoozed: return L10n.reminder_later
        default: return ""
        }
    }
}

/// 预约创建（F10 M1b 最小形态：医院/科室/时间）
struct NewAppointmentSheet: View {
    let onCreate: (String, String, Date) -> Void
    @State private var hospital = ""
    @State private var department = ""
    // 审查修复：+86400 秒跨 DST 会漂移 ±1 小时——默认日期用日历加一天（DayArithmetic）
    @State private var date = DayArithmetic.offset(days: 1)

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Form {
                    TextField(L10n.reminderApptHospital, text: $hospital)
                        .accessibilityIdentifier("SP-12.appointment.hospital")
                    TextField(L10n.reminderApptDepartment, text: $department)
                        .accessibilityIdentifier("SP-12.appointment.department")
                    DatePicker(L10n.reminderApptTime, selection: $date, in: Date()...)
                }
                .navigationTitle(L10n.reminderApptAdd)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.commonSave) { onCreate(hospital, department, date) }
                            .disabled(hospital.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("SP-12.appointment.save")
                    }
                }
            }
        }
    }
}
