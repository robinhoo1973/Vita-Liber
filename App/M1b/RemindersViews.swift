import SwiftUI
import Domain

/// 提醒模块（SP 系列 M1b 切片）：今日时段聚合卡 + 服药三选动作 + 预约列表。
/// 动效只表达状态迁移（ui-ux §1 原则 6）；敏感内容默认不展开。
struct RemindersView: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminders
    @State private var showNewAppointment = false
    @State private var showNewPlan = false

    var body: some View {
        List {
            Section(L10n.reminder_today) {
                if reminders.todaySlots.isEmpty {
                    Text(reminders.loading ? L10n.reminder_loading : L10n.reminder_todayEmpty)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("SP-09.today.empty")
                }
                ForEach(reminders.todaySlots) { slot in
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
                            // FR9.17「全部已服用」= 逐药写 taken（底层仍按单药 dose_log）
                            for record in slot.records where record.action == nil {
                                Task { await reminders.confirmTaken(patientId: currentPatientId, dose: record.dose, careMode: app.careMode) }
                            }
                        },
                        careMode: app.careMode)
                }
                // FR9.15/SP-15 计划列表入口（生命周期管理）
                NavigationLink {
                    MedicationPlanListView()
                } label: {
                    Label(L10n.planListTitle, systemImage: "list.bullet.clipboard")
                }
                .accessibilityIdentifier("SP-15.plan.list")
                Button {
                    showNewPlan = true
                } label: {
                    Label(L10n.reminder_addPlan, systemImage: "plus")
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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "stethoscope").font(.title3)   // §11-13 设计系统规则：行内小尺寸用 SF Symbols，瓷砖仅供大尺寸场景
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
                            Button {
                                Task { await reminders.completeAppointment(patientId: currentPatientId, id: apt.id) }
                            } label: {
                                Image(systemName: "checkmark.circle")
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(L10n.reminder_completeAppt)
                            .accessibilityIdentifier("SP-18.appointment.complete")
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
        .navigationTitle("提醒")
        .task(id: currentPatientId) {
            await reminders.refresh(patientId: currentPatientId)
        }
        .sheet(isPresented: $showNewAppointment) {
            NewAppointmentSheet { hospital, department, date in
                Task { await reminders.createAppointment(patientId: currentPatientId,
                                                         hospital: hospital, department: department,
                                                         startsAt: date) }
                showNewAppointment = false
            }
        }
        .sheet(isPresented: $showNewPlan) {
            NewPlanSheet { name, spec, timeText, units in
                Task {
                    do {
                        let medId = try await reminders.createMedication(
                            patientId: currentPatientId, name: name, spec: spec, unitKind: "tablet")
                        try await reminders.createPlan(
                            patientId: currentPatientId, medicationId: medId, name: name, spec: spec,
                            schedule: .fixed(times: [timeText]),
                            startDate: Calendar.current.startOfDay(for: Date()))
                    } catch {
                        // 错误经 ReminderStore Logger 上报；此处仅关闭
                    }
                }
                showNewPlan = false
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

/// 用药计划创建（评审修正 P0：提醒链用户起点——处方→计划 UI 此前缺失）
struct NewPlanSheet: View {
    let onCreate: (String, String, String, Double) -> Void
    @State private var name = ""
    @State private var spec = ""
    @State private var timeText = "08:00"
    @State private var units = 1.0

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.reminder_planName, text: $name)
                    .accessibilityIdentifier("SP-09.plan.name")
                TextField(L10n.reminder_planSpec, text: $spec)
                    .accessibilityIdentifier("SP-09.plan.spec")
                TextField(L10n.reminder_planTime, text: $timeText)
                    .accessibilityIdentifier("SP-09.plan.time")
            }
            .navigationTitle("添加用药计划")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.reminder_save) { onCreate(name, spec, timeText, units) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("SP-09.plan.save")
                }
            }
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

    var body: some View {
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
                    if allTakenHoldConfirmed {
                        Text(L10n.reminder_allTakenConfirm)
                            .font(.caption).foregroundStyle(.orange)
                        Button(L10n.reminder_allTakenYes) { onSlotAllTaken() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                                .frame(minHeight: 44)   // 触点≥44pt（审查修复）
                            .accessibilityIdentifier("SP-09.doseSlot.allTaken.confirm")
                        Button(L10n.commonCancel) { allTakenHoldConfirmed = false }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                                .frame(minHeight: 44)   // 触点≥44pt（审查修复）
                    } else {
                        Button {
                            allTakenHoldConfirmed = true
                        } label: {
                            Text(L10n.reminder_allTaken)
                                .font(.footnote)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("SP-09.doseSlot.allTaken")
                    }
                }
            }
            ForEach(slot.records, id: \DoseRecord.dose.notifyId) { record in
                HStack(spacing: 8) {
                    Text(record.displayLabel)          // 「药名 规格 · 剂量 单位」（评审阻断项修正）
                        .font(.subheadline)
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if record.action == .taken {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color("semantic-success", bundle: .main))
                            .frame(width: 44, height: 44)
                    } else if record.action != nil {
                        Text(actionShortLabel(record.action))
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                    } else {
                        // ≥44pt 横排：已服用（主）+ 稍后 Menu + 更多动作 Menu（FR9.5 全动作集）
                        Button {
                            onTaken(record.dose)
                        } label: {
                            Text(L10n.reminder_taken).frame(minWidth: 64, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel(L10n.reminder_a11yTaken(name: record.medicationName ?? L10n.reminder_medicationFallback))
                        .accessibilityIdentifier("SP-09.dose.taken")
                        Menu {
                            Button(L10n.reminder_snooze15) { onSnooze(record.dose, 15) }
                            Button(L10n.reminder_snooze30) { onSnooze(record.dose, 30) }
                            Button(L10n.reminder_snooze60) { onSnooze(record.dose, 60) }
                        } label: {
                            Text(L10n.reminder_later).frame(minWidth: 52, minHeight: 44)
                        }
                        .accessibilityIdentifier("SP-09.dose.snooze")
                        Menu {
                            Button(L10n.reminder_skip) { skipCandidate = record.dose }
                            Button(L10n.reminder_forgot) { onForget(record.dose) }
                            Button(L10n.reminder_discomfort) { discomfortCandidate = record.dose }
                        } label: {
                            Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
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
        NavigationStack {
            Form {
                TextField("医院", text: $hospital)
                    .accessibilityIdentifier("SP-12.appointment.hospital")
                TextField("科室", text: $department)
                    .accessibilityIdentifier("SP-12.appointment.department")
                DatePicker("时间", selection: $date, in: Date()...)
            }
            .navigationTitle("添加预约")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onCreate(hospital, department, date) }
                        .disabled(hospital.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("SP-12.appointment.save")
                }
            }
        }
    }
}
