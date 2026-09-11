import SwiftUI
import Domain
import Infrastructure

// MARK: - F10 预约与复诊（SP-18 · FR10.1-10.7）

/// 改期种子：已过开始时间仍 scheduled 的预约，startsAt 为过去时刻，
/// 落在 DatePicker in: Date()... 范围外——钳制到「现在」，防保存回过去
/// 日期（过去预约的负偏移提醒层级全部不补发，改期即失声）。列表/详情同源。
private func rescheduleSeed(from startsAt: Date) -> Date {
    max(startsAt, Date())
}

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
    /// FR10.7 标记错过需确认（此前零门槛直写：未来预约可被误标错过、
    /// 四档分级提醒被取消、2h 跟进提前武装）
    @State private var missTarget: AppointmentRow?
    /// FR10.7 标记完成需确认（与错过同级明示后果，杜绝未来预约一触即完成）
    @State private var completeTarget: AppointmentRow?

    private let statuses = ["scheduled", "completed", "cancelled", "missed"]

    /// scheduled 行操作钮（拆子视图：四钮重复修饰符链曾致 Swift 6 类型检查
    /// 超时 CI 编译红——统一 .apptRowButton 样式 + 独立 subview 收敛表达式体量）
    @ViewBuilder
    private func scheduledActions(for apt: AppointmentRow) -> some View {
        HStack(spacing: 10) {
            Button(L10n.apptReschedule) {
                rescheduleTarget = apt
                newDate = rescheduleSeed(from: apt.startsAt)
            }
            .apptRowButton()
            Button(L10n.apptCancel) {
                cancelTarget = apt
            }
            .apptRowButton()
            // 第七轮全仓审查修复：FR10.7「标记错过」此前无任何入口——scheduled 行
            // 只有改期/取消/完成，missed 状态与 FR10.3 错过跟进提醒（2h 后）全链路
            // 不可达。时间门槛（Domain AppointmentRules 单一出口）+ 确认（store 注释
            // 自认「按钮无时间门槛」）：未到开始时间不呈现，防未来预约被误标错过
            if AppointmentRules.canMarkMissed(startsAt: apt.startsAt) {
                Button(L10n.apptMarkMissed) {
                    missTarget = apt
                }
                .apptRowButton()
            }
            // 审查修复（FR10.7 对称性）：标记完成此前无确认、无时间门槛——
            // 未来预约一触即完成（提醒全取消 + 未来日期的复诊就诊落库）。
            // 标记错过已有 canMarkMissed 门槛 + 确认，完成必须同级确认。
            // 时间门槛（审查轮4 跟进项 2026-09-11）：未到开始时间不呈现——
            // 与 canMarkMissed 同源规则（AppointmentRules.canMarkCompleted）。
            if AppointmentRules.canMarkCompleted(startsAt: apt.startsAt) {
                Button(L10n.apptComplete) {
                    completeTarget = apt
                }
                .apptRowButton(prominent: true)
            }
        }
    }

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
                                scheduledActions(for: apt)
                            } else if apt.status == "missed" {
                                Button(L10n.apptFollowUpHint) {
                                    Task {
                                        await reminders.markAppointmentMissed(patientId: app.currentPatientId, id: apt.id)
                                        await load()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .frame(minHeight: 44)   // 触点≥44pt（审查修复）
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
                .accessibilityLabel(L10n.appointmentAdd)
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
            Button(L10n.commonCancel, role: .cancel) { cancelTarget = nil }
        }
        // 标记错过确认（取消分级提醒 + 2h 跟进，需明示后果）。
        // presenting: 形式直接注入目标行——按钮动作不再依赖与对话框
        // 关闭 setter 的共享可变状态竞态（动作/置 nil 顺序无关）
        .confirmationDialog(L10n.apptMarkMissed, isPresented:
            Binding(get: { missTarget != nil }, set: { if !$0 { missTarget = nil } }),
                            titleVisibility: .visible, presenting: missTarget) { apt in
            Button(L10n.apptMarkMissed, role: .destructive) {
                Task {
                    await reminders.markAppointmentMissed(patientId: app.currentPatientId, id: apt.id)
                    await load()
                }
            }
            Button(L10n.commonCancel, role: .cancel) { }
        } message: { _ in
            Text(L10n.apptMarkMissedHint)
        }
        // 标记完成确认（与标记错过同级明示：取消全部分级提醒 + 补录就诊记录）
        .confirmationDialog(L10n.apptComplete, isPresented:
            Binding(get: { completeTarget != nil }, set: { if !$0 { completeTarget = nil } }),
                            titleVisibility: .visible, presenting: completeTarget) { apt in
            Button(L10n.apptComplete) {
                Task {
                    await reminders.completeAppointment(patientId: app.currentPatientId, id: apt.id)
                    await load()
                }
            }
            Button(L10n.commonCancel, role: .cancel) { }
        } message: { _ in
            Text(L10n.apptCompleteHint)
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
        case "missed": return Color("semantic-danger", bundle: .main)
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
    @State private var startsAt = DayArithmetic.offset(days: 1)
    @State private var notes = ""
    @State private var itemsToBring = ""
    // FR10.2 复诊规则五种：指定日期 / N 天周月后 / 检查完成后 / 疗程结束后 / 慢病随访
    @State private var followUpRule = 0
    @State private var followUpDays = 90
    @State private var followUpDate = DayArithmetic.offset(days: 90)

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
                        // N 天/周/月后：必须确认到具体日期方可生效。
                        // 双控件互为投影（日历日差，DST 安全）：此前只有
                        // DatePicker→days 单向同步，Stepper 拨动后日期显示
                        // 与保存值分叉（提醒提前/推迟于用户看到的日期响起）
                        Stepper(L10n.apptFollowUpDays(followUpDays), value: $followUpDays, in: 1...730)
                        DatePicker(L10n.apptFollowUpConcreteDate, selection: $followUpDate,
                                   displayedComponents: .date)
                        .onChange(of: followUpDate) { _, date in
                            // 审查修复：原绑定 get 每次渲染从 Date() 重算、set 用 86400
                            // 整除截断——选中的日期最多提前一天且随渲染漂移。
                            // 以日历日差反推天数（DST 安全），日期为唯一事实源。
                            let cal = Calendar.current
                            let startDay = cal.startOfDay(for: startsAt)
                            let days = cal.dateComponents([.day], from: startDay,
                                                          to: cal.startOfDay(for: date)).day ?? 0
                            if days < 1 {
                                // 审查修复：选到就诊当天/之前时旧实现 max(1, days)
                                // 让 followUpDays 恒为 1、onChange 不再触发——
                                // 界面显示的过去日期与保存值（startsAt+1 天）
                                // 分叉，提醒在用户没看到的日期响起。回弹到
                                // 最早合法日（就诊次日起）并同步天数。
                                followUpDays = 1
                                followUpDate = DayArithmetic.offset(days: 1, from: startDay)
                            } else {
                                followUpDays = days
                            }
                        }
                        .onChange(of: followUpDays) { _, days in
                            let cal = Calendar.current
                            followUpDate = DayArithmetic.offset(days: days, from: cal.startOfDay(for: startsAt))
                        }
                        // 预约日期改动后投影重新锚定——此前具体日期仍按旧
                        // startsAt 计算，提醒在用户看到的新就诊日上提前/推迟响起
                        .onChange(of: startsAt) { _, newDate in
                            followUpDate = DayArithmetic.offset(days: followUpDays,
                                                                from: Calendar.current.startOfDay(for: newDate))
                        }
                        // 首次进入/重新进入规则 1：默认值（now+90）锚定到
                        // startsAt——否则初始 DatePicker 显示与保存值差一天
                        // （startsAt 默认明天，store 按 startsAt+days 排期）
                        .onAppear {
                            followUpDate = DayArithmetic.offset(days: followUpDays,
                                                                from: Calendar.current.startOfDay(for: startsAt))
                        }
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
                    Button(L10n.commonCancel) { dismiss() }
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
        // 规则 2/3（检查完成后/疗程结束后）无法落具体日期 → 本次不排复诊提醒，
        // 保存预约本身（预约提醒照常）；复诊日期留待用户稍后确认（FR10.2）。
        // 审查修复：医生/地址/物品/备注与复诊配置此前被静默丢弃——全部随单保存
        Task {
            await reminders.createAppointment(patientId: app.currentPatientId,
                                              hospital: hospital,
                                              department: department,
                                              startsAt: startsAt,
                                              doctor: doctor.isEmpty ? nil : doctor,
                                              address: address.isEmpty ? nil : address,
                                              itemsToBring: itemsToBring.isEmpty ? nil : itemsToBring,
                                              notes: notes.isEmpty ? nil : notes,
                                              followUpRule: followUpRule,
                                              followUpDays: followUpRule == 1 || followUpRule == 4 ? followUpDays : nil)
            dismiss()
        }
    }
}

/// §5.45 通知点击直达（V3.72）：预约提醒点击后落到该预约详情卡，
/// 而非预约列表（契约「点预约提醒直达该预约」）。查询不到（已删除/跨成员）
/// 回落可见降级，绝不 crash（缺路由降级纪律不变）。
struct AppointmentDetailRouteView: View {
    let appointmentId: UUID
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminders
    @State private var apt: AppointmentRow?
    @State private var showReschedule = false
    @State private var newDate = DayArithmetic.offset(days: 1)

    var body: some View {
        Group {
            if let apt {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(apt.hospital).font(.title3.bold())
                            Text("\(apt.department)").font(.subheadline)
                            Text(apt.startsAt.formatted(date: .long, time: .shortened))
                                .font(.body).monospacedDigit()
                            Text(L10n.apptStatusName(apt.status))
                                .font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(Color(.systemGray5)))
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text(L10n.apptListTitle)
                    }
                    if apt.status == "scheduled" {
                        Section {
                            // 第六轮全仓审查修复：改期此前打开新建表单——
                            // save 走 createAppointment 生成一张**新**预约，
                            // 原预约仍在 scheduled 态继续响铃（重复预约 +
                            // 从未发生的改期）。与列表页同用 reschedule
                            // 语义（原预约保留历史 + 新草稿）
                            Button(L10n.apptReschedule) {
                                newDate = rescheduleSeed(from: apt.startsAt)
                                showReschedule = true
                            }
                        }
                    }
                }
            } else {
                RouteFallbackView(route: .appointmentDetail(appointmentId))
            }
        }
        .navigationTitle(L10n.apptListTitle)
        .task { await load() }
        .sheet(isPresented: $showReschedule) {
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
                                                                      id: appointmentId, to: newDate)
                                showReschedule = false
                                await load()
                            }
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        let history = await reminders.appointmentHistory(patientId: app.currentPatientId)
        apt = history.first { $0.id == appointmentId }
    }
}

/// 预约行操作钮统一样式：触点 ≥44pt（ui-ux 设计系统）
private extension View {
    func apptRowButton(prominent: Bool = false) -> some View {
        Group {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .frame(minHeight: 44)
    }
}
