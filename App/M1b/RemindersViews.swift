import SwiftUI
import Domain

/// 提醒模块（SP 系列 M1b 切片）：今日时段聚合卡 + 服药三选动作 + 预约列表。
/// 动效只表达状态迁移（ui-ux §1 原则 6）；敏感内容默认不展开。
struct RemindersView: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminders
    @State private var showNewAppointment = false

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
                }
                Section("近期预约") {
                    ForEach(reminders.upcomingAppointments, id: \.id) { apt in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(apt.hospital).font(.body)
                            Text("\(apt.department) · \(apt.startsAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("SP-12.appointment.row")
                    }
                    Button {
                        showNewAppointment = true
                    } label: {
                        Label("添加预约", systemImage: "plus")
                    }
                    .accessibilityIdentifier("SP-12.appointment.add")
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
        }
    }

    private var currentPatientId: UUID { app.owner?.selfPatientId ?? app.owner?.id ?? UUID() }
}

/// 时段卡：药名列表 + 三选动作（服了/跳过/稍后，ui-ux §4.12 DoseSlotCard 形态）
struct DoseSlotCard: View {
    let slot: DoseSlot
    let onTaken: (ScheduledDose) -> Void
    let onSkip: (ScheduledDose) -> Void
    let onSnooze: (ScheduledDose) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(slot.anchorTime.formatted(date: .omitted, time: .shortened))
                .font(.headline)
                .foregroundStyle(slot.allTaken ? .secondary : .primary)
            ForEach(slot.records, id: \.dose.notifyId) { record in
                HStack {
                    Text("\(record.dose.doseUnits, specifier: "%.1f") 单位")
                        .font(.subheadline)
                    Spacer()
                    if record.action == .taken {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color("grade-c", bundle: .main))
                    } else {
                        Button("服了") { onTaken(record.dose) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityIdentifier("SP-09.dose.taken")
                        Button("跳过") { onSkip(record.dose) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("SP-09.dose.skip")
                        Button("稍后") { onSnooze(record.dose) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("SP-09.dose.snooze")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
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
