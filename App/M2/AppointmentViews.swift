import SwiftUI
import Domain
import Infrastructure

// MARK: - F10 预约与复诊（SP-18 · FR10.1-10.7）

/// 预约列表：按状态分段筛选（待就诊/已完成/已取消/错过）；
/// 行 = TaskCard 变体（医院 + 日期 + 状态胶囊）。
/// 详情底部：改期（原预约保留历史）/取消（选填原因）/标记完成（提示补录就诊）/标记错过。
struct AppointmentListView: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminders
    @State private var rows: [AppointmentRow] = []
    @State private var statusFilter = "scheduled"
    @State private var showForm = false
    @State private var cancelTarget: AppointmentRow?
    @State private var rescheduleTarget: AppointmentRow?
    @State private var newDate = Date()

    private let statuses = ["scheduled", "completed", "cancelled", "missed"]

    var body: some View {
        Group {
            let filtered = rows.filter { $0.status == statusFilter }
            if filtered.isEmpty {
                ContentUnavailableView(L10n.apptEmpty, systemImage: "calendar.badge.plus",
                                       description: Text(L10n.apptEmptyHint))
                    .accessibilityIdentifier("SP-18.appointment.empty")
            } else {
                List {
                    ForEach(filtered, id: \.id) { apt in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(apt.hospital).font(.headline)
                                    Text("\(apt.department) · \(apt.startsAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(L10n.apptStatusName(apt.status))
                                    .font(.caption2)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(statusColor(apt.status).opacity(0.15)))
                                    .foregroundStyle(statusColor(apt.status))
                            }
                            if apt.status == "scheduled" {
                                HStack(spacing: 10) {
                                    Button(L10n.apptReschedule) {
                                        rescheduleTarget = apt
                                        newDate = apt.startsAt
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    Button(L10n.apptCancel) {
                                        cancelTarget = apt
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    Button(L10n.apptComplete) {
                                        Task {
                                            await reminders.completeAppointment(patientId: app.currentPatientId, id: apt.id)
                                            await load()
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            } else if apt.status == "missed" {
                                Button(L10n.apptFollowUpHint) {
                                    Task {
                                        await reminders.markAppointmentMissed(patientId: app.currentPatientId, id: apt.id)
                                        await load()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            // FR10.6 去挂号深链卡（本地映射表，无网可用）
                            if apt.status == "scheduled" {
                                AppointmentDeepLinkCard(hospital: apt.hospital)
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("SP-18.appointment.row.\(apt.id.uuidString)")
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("", selection: $statusFilter) {
                ForEach(statuses, id: \.self) { s in
                    Text(L10n.apptStatusName(s)).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .navigationTitle(L10n.apptListTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("SP-18.appointment.add")
            }
        }
        .sheet(isPresented: $showForm) {
            AppointmentFormView()
        }
        // FR10.7 取消选填原因
        .confirmationDialog(L10n.apptCancel, isPresented: cancelBinding, titleVisibility: .visible) {
            Button(L10n.apptCancelReasonNone) { submitCancel(nil) }
            Button(L10n.apptCancelReasonDoctor) { submitCancel("doctor_rescheduled") }
            Button(L10n.apptCancelReasonSelf) { submitCancel("self") }
            Button(L10n.apptCancelReasonOther) { submitCancel("other") }
            Button(L10n.common_cancel, role: .cancel) { cancelTarget = nil }
        }
        // FR10.7 改期（原预约保留历史 + 新草稿）
        .sheet(item: $rescheduleTarget) { apt in
            NavigationStack {
                Form {
                    DatePicker(L10n.apptNewDate, selection: $newDate, in: Date()...)
                }
                .navigationTitle(L10n.apptReschedule)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.reminder_save) {
                            Task {
                                await reminders.rescheduleAppointment(patientId: app.currentPatientId,
                                                                      id: apt.id, to: newDate)
                                rescheduleTarget = nil
                                await load()
                            }
                        }
                    }
                }
            }
        }
        .task(id: app.currentPatientId) { await load() }
    }

    private var cancelBinding: Binding<Bool> {
        Binding(get: { cancelTarget != nil }, set: { if !$0 { cancelTarget = nil } })
    }

    private func submitCancel(_ reason: String?) {
        if let apt = cancelTarget {
            Task {
                await reminders.cancelAppointment(patientId: app.currentPatientId,
                                                  id: apt.id, reason: reason)
                await load()
            }
        }
        cancelTarget = nil
    }

    private func load() async {
        rows = await reminders.appointmentHistory(patientId: app.currentPatientId)
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "scheduled": return Color("brand-primary", bundle: .main)
        case "completed": return Color("semantic-success", bundle: .main)
        case "cancelled": return Color("text-secondary", bundle: .main)
        case "missed": return .red
        default: return .secondary
        }
    }
}

/// 预约表单（FR10.1 字段 + FR10.2 复诊规则五种）。
/// 模糊医嘱（「3 个月后」）必须由用户确认到具体日期方可生效（FR10.2）；
/// 「检查完成后/疗程结束后」无具体日期 → 只能保存为待确认草稿（不排提醒）。
struct AppointmentFormView: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminders
    @Environment(\.dismiss) private var dismiss

    @State private var hospital = ""
    @State private var department = ""
    @State private var doctor = ""
    @State private var address = ""
    @State private var startsAt = Date().addingTimeInterval(86400)
    @State private var notes = ""
    @State private var itemsToBring = ""
    // FR10.2 复诊规则五种：指定日期 / N 天周月后 / 检查完成后 / 疗程结束后 / 慢病随访
    @State private var followUpRule = 0
    @State private var followUpDays = 90
    @State private var followUpDate = Date().addingTimeInterval(90 * 86400)

    private let rules = [0, 1, 2, 3, 4]

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.apptFormBasic) {
                    TextField(L10n.encounterFormHospital, text: $hospital)
                    TextField(L10n.encounterFormDepartment, text: $department)
                    TextField(L10n.encounterFormDoctor, text: $doctor)
                    TextField(L10n.apptFormAddress, text: $address)
                    DatePicker(L10n.apptFormDate, selection: $startsAt, in: Date()...)
                }
                Section(L10n.apptFormPrep) {
                    TextField(L10n.apptFormItems, text: $itemsToBring, axis: .vertical)
                    TextField(L10n.apptFormNotes, text: $notes, axis: .vertical)
                }
                // FR10.2 复诊规则（可选设置；模糊规则必须落具体日期）
                Section(L10n.apptFormFollowUpRule) {
                    Picker(L10n.apptFormFollowUpRule, selection: $followUpRule) {
                        ForEach(rules, id: \.self) { r in Text(L10n.apptFollowUpRuleName(r)) }
                    }
                    switch followUpRule {
                    case 0:
                        // 指定日期：本次预约本身即复诊
                        EmptyView()
                    case 1:
                        // N 天/周/月后：必须确认到具体日期方可生效
                        Stepper(L10n.apptFollowUpDays(followUpDays), value: $followUpDays, in: 1...730)
                        DatePicker(L10n.apptFollowUpConcreteDate,
                                   selection: Binding(
                                    get: { Date().addingTimeInterval(TimeInterval(followUpDays * 86400)) },
                                    set: { followUpDays = max(1, Int($0.timeIntervalSinceNow / 86400)) }),
                                   displayedComponents: .date)
                    case 2, 3:
                        // 检查完成后/疗程结束后：无具体日期 → 待确认草稿（不排提醒）
                        Text(L10n.apptFollowUpDraftOnly)
                            .font(.footnote).foregroundStyle(.orange)
                    case 4:
                        // 慢病定期随访：N 天后
                        Stepper(L10n.apptFollowUpDays(followUpDays), value: $followUpDays, in: 1...730)
                    default:
                        EmptyView()
                    }
                }
            }
            .navigationTitle(L10n.apptFormTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.common_cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.reminder_save) { save() }
                        .disabled(hospital.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("SP-18.appointment.form.save")
                }
            }
        }
    }

    private func save() {
        // 规则 2/3（检查完成后/疗程结束后）无法落具体日期 → 本次不排提醒，
        // 保存预约本身（预约提醒照常）；复诊日期留待用户稍后确认（FR10.2）
        Task {
            await reminders.createAppointment(patientId: app.currentPatientId,
                                              hospital: hospital,
                                              department: department,
                                              startsAt: startsAt)
            dismiss()
        }
    }
}
