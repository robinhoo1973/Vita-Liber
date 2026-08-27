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
        NavigationStack {
            List {
                Section("今日用药") {
                    if reminders.todaySlots.isEmpty {
                        Text(reminders.loading ? "加载中…" : "今天没有待服药")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("SP-09.today.empty")
                    }
                    ForEach(reminders.todaySlots) { slot in
                        DoseSlotCard(slot: slot) { dose in
                            Task { await reminders.confirmTaken(patientId: currentPatientId, dose: dose) }
                        } onSkip: { dose in
                            Task { await reminders.skipDose(dose: dose) }
                        } onSnooze: { dose in
                            Task { await reminders.snoozeDose(dose: dose, patientId: currentPatientId) }
                        }
                    }
                    Button {
                        showNewPlan = true
                    } label: {
                        Label("添加用药计划", systemImage: "plus")
                    }
                    .accessibilityIdentifier("SP-09.plan.add")
                }
                Section("近期预约") {
                    if reminders.upcomingAppointments.isEmpty {
                        Text(L10n.reminder_emptyAppt)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("SP-18.appointment.empty")
                    }
                    ForEach(reminders.upcomingAppointments, id: \.id) { apt in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                VLIcon.appointment.resizable().frame(width: 32, height: 32)
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
                                .accessibilityLabel("标记就诊完成")
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
                        Label("添加预约", systemImage: "plus")
                    }
                    .accessibilityIdentifier("SP-18.appointment.add")
                }
            }
            .navigationTitle("提醒")
            .task {
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
    }

    private var currentPatientId: UUID { app.owner?.selfPatientId ?? app.owner?.id ?? UUID() }

    private func statusLabel(_ s: String) -> String {
        switch s {
        case "scheduled": return "待就诊"
        case "completed": return "已完成"
        case "cancelled": return "已取消"
        case "missed": return "已错过"
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
                TextField("药品名（如：阿莫西林）", text: $name)
                    .accessibilityIdentifier("SP-09.plan.name")
                TextField("规格（如：0.25g）", text: $spec)
                    .accessibilityIdentifier("SP-09.plan.spec")
                TextField("服药时间（HH:mm）", text: $timeText)
                    .accessibilityIdentifier("SP-09.plan.time")
            }
            .navigationTitle("添加用药计划")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onCreate(name, spec, timeText, units) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("SP-09.plan.save")
                }
            }
        }
    }
}

/// 时段卡（评审修正批）：药名/规格可区分、≥44pt 横排三选（P-flow-3 顺序：
/// 已服用/稍后/跳过）、全部已服整卡降透明度、逐钮带药名的无障碍标签。
struct DoseSlotCard: View {
    let slot: DoseSlot
    let onTaken: (ScheduledDose) -> Void
    let onSkip: (ScheduledDose) -> Void
    let onSnooze: (ScheduledDose) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(slot.anchorTime.formatted(date: .omitted, time: .shortened))
                    .font(.headline)
                if slot.allTaken {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color("semantic-success", bundle: .main))
                    Text(L10n.reminderTakenCount(slot.records.count, slot.records.count))
                        .font(.footnote)
                        .foregroundStyle(Color("semantic-success", bundle: .main))
                }
            }
            ForEach(slot.records, id: \.dose.notifyId) { record in
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
                    } else {
                        // ≥44pt 高横排三选；顺序对齐 P-flow-3（已服用/稍后/跳过）
                        Button {
                            onTaken(record.dose)
                        } label: {
                            Text(L10n.reminder_taken).frame(minWidth: 64, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("\(record.medicationName ?? "药品")，已服用")
                        .accessibilityIdentifier("SP-09.dose.taken")
                        Button {
                            onSnooze(record.dose)
                        } label: {
                            Text(L10n.reminder_later).frame(minWidth: 56, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("\(record.medicationName ?? "药品")，稍后提醒")
                        .accessibilityIdentifier("SP-09.dose.snooze")
                        Button {
                            onSkip(record.dose)
                        } label: {
                            Text(L10n.reminder_skip).frame(minWidth: 56, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("\(record.medicationName ?? "药品")，跳过")
                        .accessibilityIdentifier("SP-09.dose.skip")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(slot.allTaken ? 0.55 : 1.0)          // ui-ux §4.21：全部已服整卡降透明度
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-09.doseSlot.card")
    }
}

/// 预约创建（F10 M1b 最小形态：医院/科室/时间）
struct NewAppointmentSheet: View {
    let onCreate: (String, String, Date) -> Void
    @State private var hospital = ""
    @State private var department = ""
    @State private var date = Date().addingTimeInterval(86400)

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
