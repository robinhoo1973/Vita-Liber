import SwiftUI
import Domain
import Infrastructure
import Perception

// MARK: - v42 用药计划 = 时段模板（2026-10-23 业主裁决）
//
// 用药计划只描述「一天中的哪几个时刻该提醒」，与药品无关；把药品与计划关联
// 是「用药提醒」的动作（`MedicationBindingFormView` → `medication_plan` 绑定行）。
// 本文件的三个视图构成循环：列表（模板）→ 详情（模板 + 已绑定药品）→ 绑定表单。

private struct MedicationScheduleStoreKey: EnvironmentKey {
    static let defaultValue: MedicationScheduleStore? = nil
}

extension EnvironmentValues {
    var medicationScheduleStore: MedicationScheduleStore? {
        get { self[MedicationScheduleStoreKey.self] }
        set { self[MedicationScheduleStoreKey.self] = newValue }
    }
}

// MARK: - 列表

/// 用药计划列表：只列时段模板。每行显示名称/时刻摘要与已绑定用药提醒数。
struct MedicationScheduleListView: View {
    @Environment(AppState.self) private var app
    @Environment(\.medicationScheduleStore) private var schedules
    @State private var templates: [MedicationScheduleStore.TemplateRow] = []
    @State private var showForm = false
    @State private var loadFailed = false

    var body: some View {
        WithPerceptionTracking {
            List {
                if loadFailed {
                    Section {
                        Text(L10n.planScheduleLoadFailed)
                            .font(.caption)
                            .foregroundStyle(Color("semantic-danger", bundle: .main))
                    }
                }
                if templates.isEmpty {
                    Section {
                        VLUnavailableView(L10n.planScheduleEmpty, systemImage: "clock",
                                         description: Text(L10n.planScheduleEmptyHint))
                            .accessibilityIdentifier("SP-15.schedule.empty")
                    }
                } else {
                    ForEach(templates) { template in
                        NavigationLink {
                            MedicationScheduleDetailView(template: template)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name ?? L10n.planScheduleUntitled)
                                    .font(.subheadline)
                                Text(MedicationScheduleTemplateRules.summary(template.times))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if template.boundPlanCount > 0 {
                                    Text(L10n.planScheduleBoundFmt(template.boundPlanCount))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .accessibilityIdentifier("SP-15.schedule.row.\(template.id.uuidString)")
                    }
                }
            }
            .frame(maxWidth: 672)
            .navigationTitle(L10n.planListTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.planAdd)
                    .accessibilityIdentifier("SP-15.schedule.add")
                }
            }
            .sheet(isPresented: $showForm) {
                MedicationScheduleFormView(mode: .create) { await load() }
            }
            .task(id: app.currentPatientId) { await load() }
        }
    }

    private func load() async {
        guard let schedules else { return }
        do {
            templates = try await schedules.list(patientId: app.currentPatientId)
            loadFailed = false
        } catch {
            loadFailed = true   // 读失败保留旧列表（同族 doctrine：不渲染假空态）
        }
    }
}

// MARK: - 新建 / 编辑表单（只有时段）

struct MedicationScheduleFormView: View {
    enum Mode {
        case create
        case edit(MedicationScheduleStore.TemplateRow)
    }

    @Environment(AppState.self) private var app
    @Environment(\.medicationScheduleStore) private var schedules
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let onSaved: () async -> Void

    @State private var name = ""
    @State private var selectedSlots: Set<DoseTimeSlot> = [.beforeBreakfast]
    @State private var slotTimeTexts: [DoseTimeSlot: String] = [:]
    @State private var customTimes = ""
    @State private var saveFailed = false
    @State private var isSaving = false

    private var selectedSlotList: [DoseTimeSlot] {
        DoseTimeSlot.allCases.filter { selectedSlots.contains($0) }
    }

    private var slotTimes: [String] {
        DoseTimeSlotRules.times(selectedSlotList, overrides: slotTimeTexts)
    }

    private var customTimeList: [String] {
        customTimes.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var allTimes: [String] {
        MedicationScheduleTemplateRules.normalize(slotTimes + customTimeList)
    }

    private var invalidCustomTime: Bool {
        customTimeList.contains { !DoseScheduleEngine.isValidTime($0) }
    }

    private var duplicateTimes: Bool {
        let minutes = (selectedSlotList.map { slotTimeTexts[$0] ?? $0.defaultTime } + customTimeList)
            .compactMap { DoseScheduleEngine.minutes($0) }
        return Set(minutes).count != minutes.count
    }

    private var missingTime: Bool { allTimes.isEmpty }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Form {
                    Section {
                        TextField(L10n.planScheduleNamePlaceholder, text: $name)
                            .accessibilityIdentifier("SP-15.schedule.form.name")
                    }
                    Section(L10n.planFormSlots) {
                        ForEach(DoseTimeSlot.allCases, id: \.self) { slot in
                            HStack(spacing: 8) {
                                Toggle(slot.localizedTitle, isOn: slotBinding(slot))
                                if selectedSlots.contains(slot) {
                                    DatePicker("", selection: slotTimeBinding(slot),
                                               displayedComponents: .hourAndMinute)
                                        .labelsHidden()
                                }
                            }
                        }
                        TextField(L10n.planFormFixedTimes, text: $customTimes)
                            .accessibilityIdentifier("SP-15.schedule.form.customTimes")
                        if missingTime {
                            errorText(L10n.planFormSlotMissing)
                        }
                        if invalidCustomTime {
                            errorText(L10n.planFormCustomTimesInvalid)
                        }
                        if !invalidCustomTime && duplicateTimes {
                            errorText(L10n.planFormSlotDuplicate)
                        }
                    }
                }
                .navigationTitle(isEditing ? L10n.planScheduleEditTitle : L10n.planAdd)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.commonCancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.commonSave) { save() }
                            .disabled(!canSave)
                            .accessibilityIdentifier("SP-15.schedule.form.save")
                    }
                }
            }
            .onAppear(perform: seed)
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var canSave: Bool {
        !isSaving && !missingTime && !invalidCustomTime && !duplicateTimes
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color("semantic-danger", bundle: .main))
    }

    private func seed() {
        guard case .edit(let row) = mode, name.isEmpty, slotTimeTexts.isEmpty else { return }
        name = row.name ?? ""
        // 回填：能精确匹配到时段默认时刻的用时段；其余进自定义时刻。
        var customs: [String] = []
        for time in row.times {
            if let slot = DoseTimeSlot.allCases.first(where: { $0.defaultTime == time }) {
                selectedSlots.insert(slot)
            } else {
                customs.append(time)
            }
        }
        if selectedSlots.isEmpty { selectedSlots = [.beforeBreakfast] }
        customTimes = customs.joined(separator: ",")
    }

    private func save() {
        guard let schedules else { return }
        if let error = MedicationScheduleTemplateRules.validate(allTimes) {
            _ = error   // 表单已就地红字；此处只兜底拒绝
            return
        }
        isSaving = true
        let times = MedicationScheduleTemplateRules.normalize(allTimes)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName: String? = trimmed.isEmpty ? nil : trimmed
        Task {
            do {
                switch mode {
                case .create:
                    try await schedules.create(patientId: app.currentPatientId,
                                               name: displayName, times: times)
                case .edit(let row):
                    try await schedules.update(id: row.id, name: displayName, times: times)
                }
                await onSaved()
                dismiss()
            } catch {
                saveFailed = true
                isSaving = false
            }
        }
    }

    private func slotBinding(_ slot: DoseTimeSlot) -> Binding<Bool> {
        Binding(
            get: { selectedSlots.contains(slot) },
            set: { isOn in
                if isOn { selectedSlots.insert(slot) } else { selectedSlots.remove(slot) }
            })
    }

    private func slotTimeBinding(_ slot: DoseTimeSlot) -> Binding<Date> {
        Binding(
            get: { DoseTimeSlotRules.date(for: slotTimeTexts[slot] ?? slot.defaultTime) ?? Date() },
            set: { slotTimeTexts[slot] = DoseTimeSlotRules.timeString(from: $0) })
    }
}

// MARK: - 模板详情（时段 + 已绑定用药提醒）

struct MedicationScheduleDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.medicationScheduleStore) private var schedules
    @Environment(\.dismiss) private var dismiss

    @State private var template: MedicationScheduleStore.TemplateRow
    @State private var bindings: [MedicationScheduleStore.BindingRow] = []

    init(template: MedicationScheduleStore.TemplateRow) {
        _template = State(initialValue: template)
    }
    @State private var showEdit = false
    @State private var showBind = false
    @State private var actionFailed = false
    @State private var deleteBlocked = false

    var body: some View {
        WithPerceptionTracking {
            List {
                Section(L10n.planFormSlots) {
                    ForEach(MedicationScheduleTemplateRules.normalize(template.times), id: \.self) { time in
                        Text(time).font(.body.monospacedDigit())
                    }
                }
                Section(L10n.planScheduleBindings) {
                    if bindings.isEmpty {
                        Text(L10n.planScheduleNoBindings)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(bindings) { binding in
                            NavigationLink {
                                MedicationPlanDetailView(planId: binding.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(binding.medicationName).font(.subheadline)
                                    if let spec = binding.spec {
                                        Text(spec).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    Button {
                        showBind = true
                    } label: {
                        Label(L10n.planScheduleBindDrug, systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("SP-15.schedule.bind")
                }
                if actionFailed {
                    Section {
                        Text(L10n.problemSaveFailedHint)
                            .font(.caption)
                            .foregroundStyle(Color("semantic-danger", bundle: .main))
                    }
                }
                if deleteBlocked {
                    Section {
                        Text(L10n.planScheduleDeleteBlocked)
                            .font(.caption)
                            .foregroundStyle(Color("semantic-danger", bundle: .main))
                    }
                }
                Section {
                    Button(L10n.planScheduleDelete, role: .destructive) { delete() }
                }
            }
            .navigationTitle(template.name ?? L10n.planScheduleUntitled)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.planScheduleEdit) { showEdit = true }
                        .accessibilityIdentifier("SP-15.schedule.edit")
                }
            }
            .sheet(isPresented: $showEdit) {
                MedicationScheduleFormView(mode: .edit(template)) { await reloadTemplate() }
            }
            .sheet(isPresented: $showBind) {
                MedicationBindingFormView(template: template) { await load() }
            }
            .onChangeCompat(of: showBind) { _, showing in
                if !showing { Task { await load() } }   // 绑定表单自身 dismiss
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let schedules else { return }
        do { bindings = try await schedules.bindings(scheduleId: template.id) } catch { }
    }

    private func reloadTemplate() async {
        guard let schedules else { return }
        if let fresh = try? await schedules.template(id: template.id) {   // try?-ok: 刷新失败保留旧值，不打断编辑后的页面
            template = fresh
        }
    }

    private func delete() {
        guard let schedules else { return }
        Task {
            do {
                try await schedules.delete(id: template.id)
                dismiss()
            } catch MedicationScheduleStore.StoreError.inUse {
                deleteBlocked = true
            } catch {
                actionFailed = true
            }
        }
    }
}

// MARK: - 绑定表单（用药提醒 = 药品 × 计划）

/// 复用完整计划表单（药品/剂量/库存批次/医嘱），时刻与模板绑定由
/// `scheduleTemplate` 注入：表单内不再编辑时段。
struct MedicationBindingFormView: View {
    let template: MedicationScheduleStore.TemplateRow
    let onSaved: () async -> Void

    var body: some View {
        MedicationPlanFormView(scheduleTemplate: template)
    }
}
