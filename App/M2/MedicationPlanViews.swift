import SwiftUI
import Domain
import Infrastructure

// MARK: - FR9.15/SP-15 用药计划列表

/// 用药计划列表（SP-15 切片）：按状态分组（进行中/已暂停/已结束）。
/// 入口：提醒模块顶部；计划行点击进入详情（§5.26 生命周期操作）。
struct MedicationPlanListView: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminders
    @State private var plans: [MedicationStore.PlanRow] = []
    @State private var showForm = false

    var body: some View {
        List {
            ForEach(plans) { plan in
                NavigationLink {
                    MedicationPlanDetailView(planId: plan.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.medicationName).font(.subheadline)
                            if let spec = plan.spec {
                                Text(spec).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        PlanStatusBadge(status: plan.status)
                    }
                }
                .accessibilityIdentifier("SP-15.plan.row.\(plan.id.uuidString)")
            }
        }
        .navigationTitle(L10n.planListTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("SP-15.plan.add")
            }
        }
        .sheet(isPresented: $showForm) {
            MedicationPlanFormView()
        }
        .task(id: app.currentPatientId) { await load() }
    }

    private func load() async {
        do {
            plans = try await reminders.plans(patientId: app.currentPatientId)
        } catch {
            plans = []
        }
    }
}

// MARK: - FR9.15/§5.9/§5.26 计划详情

/// 用药计划详情：头部（药名/规格/状态）+ 本周日程条（FR9.16 补记）+
/// 今日剂量队列 + 医嘱原文引用块 + 生命周期操作区 + 计划历史时间轴。
/// 系统不提供任何建议性措辞（BR-006）；结束用药必须用户显式操作并选填原因。
struct MedicationPlanDetailView: View {
    let planId: UUID
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminders
    @State private var plan: MedicationStore.PlanRow?
    @State private var weekLog: [MedicationStore.DoseLogRow] = []
    @State private var history: [PlanLifecycleEvent] = []
    @State private var showEndConfirm = false
    @State private var showBackfill = false
    @State private var backfillTarget: Date?

    var body: some View {
        List {
            if let plan {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plan.medicationName).font(.headline)
                            if let spec = plan.spec {
                                Text(spec).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        PlanStatusBadge(status: plan.status)
                    }
                }
                .accessibilityIdentifier("SP-15.detail.header")

                // FR9.16 日程条：本周七日格，已服实心✓/漏服空心!/未来灰
                Section(L10n.planWeekStrip) {
                    WeekStrip(rows: weekLog) { row in
                        guard row.action == nil || row.action == .missed else { return }
                        backfillTarget = row.scheduledFor
                        showBackfill = true
                    }
                    .accessibilityIdentifier("SP-15.detail.week")
                }

                // 今日剂量队列（当前时段项放大高亮）
                Section(L10n.planTodayDoses) {
                    ForEach(todayRows) { row in
                        HStack {
                            Text(row.scheduledFor.formatted(date: .omitted, time: .shortened))
                                .font(.subheadline).monospacedDigit()
                            Spacer()
                            Text(actionLabel(row.action)).font(.caption)
                                .foregroundStyle(actionColor(row.action))
                        }
                    }
                    if todayRows.isEmpty {
                        Text(L10n.planNoTodayDose).font(.caption).foregroundStyle(.secondary)
                    }
                }

                // 医嘱原文引用块（A/C 来源徽章；不可编辑）
                if let advice = planAdviceText, !advice.isEmpty {
                    Section(L10n.planAdviceText) {
                        Text(advice)
                            .font(.body)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Color("brand-primary", bundle: .main))
                                    .frame(width: 3)
                            }
                        Text(L10n.planAdviceSource)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                // §5.26 生命周期操作区（按钮随状态变化）
                Section {
                    switch plan.status {
                    case "active":
                        Button(L10n.planPause) {
                            Task { await reminders.pausePlan(planId: planId) }
                        }
                        .accessibilityIdentifier("SP-15.detail.pause")
                        Button(L10n.planEnd, role: .destructive) {
                            showEndConfirm = true
                        }
                        .accessibilityIdentifier("SP-15.detail.end")
                    case "paused":
                        Button(L10n.planResume) {
                            Task { await reminders.resumePlan(planId: planId) }
                        }
                        .accessibilityIdentifier("SP-15.detail.resume")
                        Button(L10n.planEnd, role: .destructive) {
                            showEndConfirm = true
                        }
                    default:
                        Text(L10n.planEndedNote).font(.caption).foregroundStyle(.secondary)
                    }
                }

                // FR9.15 计划历史时间轴（开始/调整/暂停/恢复/结束）
                if !history.isEmpty {
                    Section(L10n.planHistory) {
                        ForEach(history) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: eventIcon(event.kind))
                                    .foregroundStyle(Color("brand-primary", bundle: .main))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(eventLabel(event)).font(.caption)
                                    Text(event.at.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(L10n.planNotFound, systemImage: "pills")
            }
        }
        .navigationTitle(L10n.planDetailTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let plan {
                ToolbarItem(placement: .topBarTrailing) {
                    // FR9.9 药品知识卡入口
                    NavigationLink {
                        MedicationKnowledgeCardView(plan: plan)
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityIdentifier("SP-15.detail.knowledge")
                }
            }
        }
        .confirmationDialog(L10n.planEndConfirmTitle, isPresented: $showEndConfirm, titleVisibility: .visible) {
            ForEach(PlanEndReason.allCases, id: \.rawValue) { reason in
                Button(endReasonLabel(reason), role: .destructive) {
                    Task { await reminders.endPlan(planId: planId, reason: reason) }
                }
            }
            Button(L10n.commonCancel, role: .cancel) { }
        } message: {
            Text(L10n.planEndConfirmBody)
        }
        .sheet(isPresented: $showBackfill) {
            if let target = backfillTarget, let plan {
                BackfillSheet(plan: plan, targetTime: target)
            }
        }
        .task(id: planId) { await load() }
        .onChange(of: app.currentPatientId) { _, _ in
            Task { await load() }
        }
    }

    private var todayRows: [MedicationStore.DoseLogRow] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        return weekLog.filter { $0.scheduledFor >= start && $0.scheduledFor < end }
    }

    private var planAdviceText: String? {
        nil   // 医嘱原文来自 prescription 表（Phase 3 就诊/处方联合查询挂接）
    }

    private func load() async {
        do {
            plan = try await reminders.plan(id: planId)
            history = try await reminders.lifecycleEvents(planId: planId)
            let cal = Calendar.current
            let weekStart = cal.date(byAdding: .day, value: -6,
                                     to: cal.startOfDay(for: Date())) ?? Date()
            weekLog = try await reminders.doseLog(planId: planId, from: weekStart,
                                                  to: Date().addingTimeInterval(7 * 86400))
        } catch {
            plan = nil
        }
    }

    private func actionLabel(_ action: DoseUserAction?) -> String {
        switch action {
        case .taken: return L10n.planActionTaken
        case .skipped: return L10n.planActionSkipped
        case .missed: return L10n.planActionMissed
        case .discomfort: return L10n.planActionDiscomfort
        case .snoozed: return L10n.planActionSnoozed
        case nil: return L10n.planActionPending
        }
    }

    private func actionColor(_ action: DoseUserAction?) -> Color {
        switch action {
        case .taken: return Color("semantic-success", bundle: .main)
        case .missed, .discomfort: return .orange
        case .skipped, .snoozed: return .secondary
        case nil: return .blue
        }
    }

    private func eventIcon(_ kind: PlanLifecycleEvent.Kind) -> String {
        switch kind {
        case .started: return "play.circle"
        case .edited: return "pencil.circle"
        case .paused: return "pause.circle"
        case .resumed: return "arrow.clockwise.circle"
        case .ended: return "stop.circle"
        }
    }

    private func eventLabel(_ event: PlanLifecycleEvent) -> String {
        switch event.kind {
        case .started: return L10n.planEventStarted
        case .edited: return L10n.planEventEdited
        case .paused: return L10n.planEventPaused
        case .resumed: return L10n.planEventResumed
        case .ended: return L10n.planEventEnded(endReasonLabelText(event.note))
        }
    }

    private func endReasonLabel(_ reason: PlanEndReason) -> String {
        switch reason {
        case .doctorInstruction: return L10n.planEndDoctor
        case .courseCompleted: return L10n.planEndCourse
        case .adverseReaction: return L10n.planEndAdverse
        case .noLongerNeeded: return L10n.planEndNoLonger
        case .other: return L10n.planEndOther
        }
    }

    private func endReasonLabelText(_ raw: String?) -> String {
        guard let raw, let reason = PlanEndReason(rawValue: raw) else { return "" }
        return endReasonLabel(reason)
    }
}

/// FR9.16 日程条：本周七日格。已服实心✓ / 漏服空心!（可点补记）/ 未来灰。
private struct WeekStrip: View {
    let rows: [MedicationStore.DoseLogRow]
    let onBackfill: (MedicationStore.DoseLogRow) -> Void

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days = (0..<7).map { offset in
            cal.date(byAdding: .day, value: offset - 6, to: today) ?? today
        }
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
                let dayRows = rows.filter {
                    cal.isDate($0.scheduledFor, inSameDayAs: day)
                }
                Button {
                    // 漏服格可点补记（FR9.16）；已服/未来格不可点
                    if let missed = dayRows.first(where: { $0.action == nil || $0.action == .missed }) {
                        onBackfill(missed)
                    }
                } label: {
                    VStack(spacing: 4) {
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2).foregroundStyle(.secondary)
                        Image(systemName: daySymbol(dayRows, day: day))
                            .font(.system(size: 16))
                            .foregroundStyle(daySymbolColor(dayRows, day: day))
                        Text(day.formatted(.dateTime.day()))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(cal.isDate(day, inSameDayAs: today)
                              ? Color("brand-primary", bundle: .main).opacity(0.08)
                              : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func daySymbol(_ rows: [MedicationStore.DoseLogRow], day: Date) -> String {
        if rows.isEmpty { return "minus" }
        if rows.contains(where: { $0.action == .taken || $0.action == .discomfort }) {
            return "checkmark.circle.fill"
        }
        if rows.contains(where: { $0.action == nil || $0.action == .missed }) {
            return "exclamationmark.circle"
        }
        return "minus"
    }

    private func daySymbolColor(_ rows: [MedicationStore.DoseLogRow], day: Date) -> Color {
        if rows.isEmpty { return Color(.systemGray3) }
        if rows.contains(where: { $0.action == .taken || $0.action == .discomfort }) {
            return Color("semantic-success", bundle: .main)
        }
        if rows.contains(where: { $0.action == nil || $0.action == .missed }) { return .orange }
        return .secondary
    }
}

/// FR9.16 补记 Sheet：实际时间选择器（默认当前，可改）→ 落库后如实呈现
private struct BackfillSheet: View {
    let plan: MedicationStore.PlanRow
    let targetTime: Date
    @Environment(ReminderStore.self) private var reminders
    @Environment(\.dismiss) private var dismiss
    @State private var actualTime = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(L10n.planBackfillActualTime, selection: $actualTime, in: ...Date())
            }
            .navigationTitle(L10n.planBackfillTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.reminder_save) {
                        Task {
                            await reminders.backfillTaken(
                                planId: plan.id, patientId: plan.patientId,
                                medicationId: plan.medicationId,
                                actualTime: actualTime, doseUnits: 1)
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("SP-15.detail.backfill.save")
                }
            }
        }
        .presentationDetents([.height(220)])
    }
}

// MARK: - FR9.1-9.3 计划创建表单（处方字段全集 + 初始批次 FR9.10）

/// 用药计划创建表单：药名/商品名/规格/单次剂量/每日次数/给药方式/餐食关系/
/// 疗程起止/医院医生/医嘱原文 + 调度选择 + 初始批次（必询效期与存储位置，
/// 未知进待办队列不阻塞保存）。
/// 保存经 MedicationPlanComposer 五表原子创建（BR-003：手工来源默认全确认）。
struct MedicationPlanFormView: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminders
    @Environment(\.dismiss) private var dismiss

    @State private var genericName = ""
    @State private var brandName = ""
    @State private var spec = ""
    @State private var dosePerTake = ""
    @State private var timesPerDay = "1"
    @State private var route = ""
    @State private var mealRelation = ""
    @State private var hospital = ""
    @State private var doctor = ""
    @State private var adviceText = ""
    @State private var isLongTerm = true
    @State private var isAsNeeded = false
    @State private var startDate = Date()
    @State private var endDate = Date().addingTimeInterval(30 * 86400)
    @State private var hasEndDate = false
    // 调度：固定时间（逗号分隔 HH:mm）
    @State private var fixedTimes = "08:00"
    // FR9.10 初始批次
    @State private var lotUnits = 30.0
    @State private var lotUnitKind = "tablet"
    @State private var lotExpireDate = Date().addingTimeInterval(180 * 86400)
    @State private var lotExpireUnknown = false
    @State private var storageNote = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.planFormMedication) {
                    TextField(L10n.planFormGenericName, text: $genericName)
                    TextField(L10n.planFormBrandName, text: $brandName)
                    TextField(L10n.planFormSpec, text: $spec)
                    TextField(L10n.planFormDosePerTake, text: $dosePerTake)
                    TextField(L10n.planFormTimesPerDay, text: $timesPerDay)
                        .keyboardType(.numberPad)
                    TextField(L10n.planFormRoute, text: $route)
                    TextField(L10n.planFormMeal, text: $mealRelation)
                }
                Section(L10n.planFormSchedule) {
                    TextField(L10n.planFormFixedTimes, text: $fixedTimes)
                        .keyboardType(.numbersAndPunctuation)
                    Toggle(L10n.planFormAsNeeded, isOn: $isAsNeeded)
                    DatePicker(L10n.planFormStartDate, selection: $startDate, displayedComponents: .date)
                    Toggle(L10n.planFormHasEndDate, isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker(L10n.planFormEndDate, selection: $endDate, displayedComponents: .date)
                    }
                    Toggle(L10n.planFormLongTerm, isOn: $isLongTerm)
                }
                Section(L10n.planFormSource) {
                    TextField(L10n.planFormHospital, text: $hospital)
                    TextField(L10n.planFormDoctor, text: $doctor)
                    TextField(L10n.planFormAdvice, text: $adviceText, axis: .vertical)
                        .lineLimit(3...6)
                }
                // FR9.10：录入时必须询问失效日期与存储位置（未知进待办队列）
                Section {
                    Stepper(L10n.planFormLotUnits(Double(Int(lotUnits))), value: $lotUnits, in: 1...1000)
                    Picker(L10n.planFormLotUnit, selection: $lotUnitKind) {
                        Text(L10n.lotUnitTablet).tag("tablet")
                        Text(L10n.lotUnitCapsule).tag("capsule")
                        Text(L10n.lotUnitPatch).tag("patch")
                        Text(L10n.lotUnitVial).tag("vial")
                    }
                    Toggle(L10n.planFormExpireUnknown, isOn: $lotExpireUnknown)
                    if !lotExpireUnknown {
                        DatePicker(L10n.planFormExpireDate, selection: $lotExpireDate, displayedComponents: .date)
                    }
                    TextField(L10n.planFormStorageNote, text: $storageNote)
                } header: {
                    Text(L10n.planFormLotSection)
                } footer: {
                    Text(L10n.planFormLotHint)
                }
            }
            .navigationTitle(L10n.planFormTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.reminder_save) { save() }
                        .disabled(genericName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("SP-15.form.save")
                }
            }
        }
    }

    private func save() {
        let times = fixedTimes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let schedule: MedicationSchedule = isAsNeeded
            ? .asNeeded
            : .fixed(times: times.isEmpty ? ["08:00"] : times)
        let source: PrescriptionSource = .manual
        let rx = Prescription(
            patientId: app.currentPatientId,
            source: source,
            genericName: genericName, brandName: brandName.isEmpty ? nil : brandName,
            spec: spec, dosePerTake: dosePerTake.isEmpty ? nil : dosePerTake,
            timesPerDay: Int(timesPerDay),
            route: route.isEmpty ? nil : route,
            timingMeal: mealRelation.isEmpty ? nil : mealRelation,
            durationStart: startDate,
            durationEnd: hasEndDate ? endDate : nil,
            hospital: hospital.isEmpty ? nil : hospital,
            doctor: doctor.isEmpty ? nil : doctor,
            adviceText: adviceText,
            isLongTerm: isLongTerm, isAsNeeded: isAsNeeded,
            confirmedFields: PrescriptionConfirmation.initialConfirmedFields(source: source))
        let draft = MedicationPlanDraft(schedule: schedule, startDate: startDate,
                                        endDate: hasEndDate ? endDate : nil)
        let lot = StockLotDraft(totalUnits: lotUnits, unitKind: lotUnitKind,
                                expireAt: lotExpireUnknown ? nil : lotExpireDate,
                                storageNote: storageNote)
        Task {
            do {
                try await reminders.createPlanFromPrescription(prescription: rx,
                                                               plan: draft, initialLot: lot)
                dismiss()
            } catch {
                // 错误经 ReminderStore Logger 上报；BR-003 拒绝时表单保留可修
            }
        }
    }
}

// MARK: - FR9.9 药品知识卡（§5.40）

/// 药品知识卡：医嘱原文（A/C 来源）+ 储存条件与注意事项（用户记录）+ 固定话术。
/// BR-006：涉及禁忌、相互作用、特殊人群一律给「引导咨询医生药师」固定话术，
/// 不给任何结论。说明书写法要点不内置药典数据——只如实呈现用户自己的记录。
struct MedicationKnowledgeCardView: View {
    let plan: MedicationStore.PlanRow
    @Environment(ReminderStore.self) private var reminders
    @State private var advice: String?

    var body: some View {
        List {
            Section {
                Text(plan.medicationName).font(.headline)
                if let spec = plan.spec {
                    Text(spec).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L10n.knowledgeAdvice) {
                if let advice, !advice.isEmpty {
                    Text(advice)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color("brand-primary", bundle: .main)).frame(width: 3)
                        }
                    Text(L10n.knowledgeAdviceBadge)
                        .font(.caption2).foregroundStyle(Color("grade-a", bundle: .main))
                } else {
                    Text(L10n.knowledgeNoAdvice).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L10n.knowledgeStorage) {
                Text(L10n.knowledgeStorageHint)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section(L10n.knowledgeCaution) {
                // BR-006 固定话术：涉及禁忌/相互作用/特殊人群不给结论
                Text(L10n.knowledgeCautionText)
                    .font(.footnote)
                    .foregroundStyle(Color("semantic-warning", bundle: .main))
            }
        }
        .navigationTitle(L10n.knowledgeTitle)
        .task { await loadAdvice() }
    }

    private func loadAdvice() async {
        do {
            advice = try await reminders.medicationAdvice(medicationId: plan.medicationId)
        } catch {
            advice = nil
        }
    }
}

// MARK: - 组件

struct PlanStatusBadge: View {
    let status: String
    var body: some View {
        Text(statusLabel)
            .font(.caption2)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
    private var statusLabel: String {
        switch status {
        case "active": return L10n.planStatusActive
        case "paused": return L10n.planStatusPaused
        case "ended": return L10n.planStatusEnded
        default: return status
        }
    }
    private var color: Color {
        switch status {
        case "active": return Color("brand-primary", bundle: .main)
        case "paused": return .orange
        case "ended": return Color("text-secondary", bundle: .main)
        default: return .secondary
        }
    }
}
