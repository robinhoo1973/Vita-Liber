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
                if templates.isEmpty && !loadFailed {
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

// MARK: - 新建 / 编辑表单（标准时段 + 常用提醒范围 + 自定义条目）
//
// 2026-10-23 业主：列出所有标准用药时段，边上给常用提醒范围，并允许自定义范围。
// 委员会裁决：time 是唯一排程事实；range 是展示元数据（半开区间），不驱动
// 通知/漏服/库存；范围值不是医学建议（BR-006），界面称「常用提醒范围」。

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
    @State private var selectedSlots: Set<DoseTimeSlot> = []
    @State private var slotTimeTexts: [DoseTimeSlot: String] = [:]
    /// 用户改过的范围；缺省 = 该时段默认范围（=`[defaultTime, defaultTime+30)`）。
    @State private var slotRangeTexts: [DoseTimeSlot: [String]] = [:]
    @State private var customEntries: [MedicationScheduleEntry] = []
    @State private var saveFailed = false
    @State private var isSaving = false

    private var selectedSlotList: [DoseTimeSlot] {
        DoseTimeSlot.allCases.filter { selectedSlots.contains($0) }
    }

    /// 未规范化的原始条目：校验必须看它——normalize 会去重，
    /// 先 normalize 再 validate 会让「重复时刻」永远抓不到。
    private var rawEntries: [MedicationScheduleEntry] {
        var list = selectedSlotList.map { slot -> MedicationScheduleEntry in
            let range = slotRangeTexts[slot]
            return MedicationScheduleEntry(
                slot: slot,
                time: slotTimeTexts[slot] ?? slot.defaultTime,
                rangeStart: range?.first,
                rangeEnd: range?.last)
        }
        list.append(contentsOf: customEntries)
        return list
    }

    private var entries: [MedicationScheduleEntry] {
        MedicationScheduleEntryRules.normalize(rawEntries)
    }

    private var validationError: MedicationScheduleEntryRules.ValidationError? {
        MedicationScheduleEntryRules.validate(rawEntries)
    }

    private var outsideRange: [MedicationScheduleEntry] {
        MedicationScheduleEntryRules.timesOutsideRange(rawEntries)
    }

    private var canSave: Bool {
        !isSaving && validationError == nil
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Form {
                    Section {
                        TextField(L10n.planScheduleNamePlaceholder, text: $name)
                            .accessibilityIdentifier("SP-15.schedule.form.name")
                    }
                    Section {
                        ForEach(DoseTimeSlot.allCases, id: \.self) { slot in
                            slotRow(slot)
                        }
                    } header: {
                        Text(L10n.planFormSlots)
                    } footer: {
                        Text(L10n.planFormSlotsHint)
                    }
                    Section(L10n.planFormCustomSection) {
                        ForEach($customEntries) { $entry in
                            customEntryRow($entry)
                        }
                        Button {
                            customEntries.append(MedicationScheduleEntry(
                                slot: nil, time: "12:00", rangeStart: "12:00", rangeEnd: "12:30"))
                        } label: {
                            Label(L10n.planFormCustomAdd, systemImage: "plus.circle")
                        }
                        .accessibilityIdentifier("SP-15.schedule.form.custom.add")
                    }
                    if let error = validationError {
                        Section {
                            errorText(validationMessage(error))
                        }
                    }
                    if !outsideRange.isEmpty {
                        // 软提示：提醒时刻不在常用范围内（不阻断保存，不改时刻）。
                        Section {
                            Text(L10n.planFormRangeNotice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if saveFailed {
                        Section {
                            errorText(L10n.planFormSaveFailedHint)
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

    // MARK: 行

    @ViewBuilder
    private func slotRow(_ slot: DoseTimeSlot) -> some View {
        let enabled = selectedSlots.contains(slot)
        let range = effectiveRange(slot)
        VStack(alignment: .leading, spacing: 4) {
            Toggle(slot.localizedTitle, isOn: slotBinding(slot))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SP-15.schedule.form.slot.\(slot.rawValue)")
            Text(L10n.planFormRangeFmt(range.start, range.end))
                .font(.caption)
                .foregroundStyle(Color("text-secondary", bundle: .main))
            if enabled {
                DatePicker(L10n.planFormSlotTimeFmt(slot.localizedTitle),
                           selection: slotTimeBinding(slot),
                           displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("SP-15.schedule.form.slot.time.\(slot.rawValue)")
                if let rangeTexts = slotRangeTexts[slot] {
                    HStack {
                        DatePicker(L10n.planFormRangeStart,
                                   selection: rangeBinding(slot, isStart: true),
                                   displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        Text("–").foregroundStyle(.secondary)
                        DatePicker(L10n.planFormRangeEnd,
                                   selection: rangeBinding(slot, isStart: false),
                                   displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        Button(L10n.planFormRangeReset) { slotRangeTexts[slot] = nil }
                            .font(.caption)
                    }
                    .accessibilityIdentifier("SP-15.schedule.form.slot.range.\(slot.rawValue)")
                } else {
                    Button(L10n.planFormRangeCustomize) {
                        slotRangeTexts[slot] = [range.start, range.end]
                    }
                    .font(.caption)
                    .accessibilityIdentifier("SP-15.schedule.form.slot.range.customize.\(slot.rawValue)")
                }
            }
        }
    }

    @ViewBuilder
    private func customEntryRow(_ entry: Binding<MedicationScheduleEntry>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DatePicker(L10n.planFormCustomTime,
                       selection: timeBinding(entry.time),
                       displayedComponents: .hourAndMinute)
            HStack {
                DatePicker(L10n.planFormRangeStart,
                           selection: customRangeBinding(entry, isStart: true),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Text("–").foregroundStyle(.secondary)
                DatePicker(L10n.planFormRangeEnd,
                           selection: customRangeBinding(entry, isStart: false),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Spacer()
                Button(role: .destructive) {
                    customEntries.removeAll { $0.id == entry.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(L10n.planFormCustomDelete)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-15.schedule.form.custom.\(entry.wrappedValue.id)")
    }

    // MARK: 状态

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private func effectiveRange(_ slot: DoseTimeSlot) -> (start: String, end: String) {
        if let texts = slotRangeTexts[slot], texts.count == 2 {
            return (texts[0], texts[1])
        }
        return MedicationScheduleEntryRules.defaultRange(for: slot)
    }

    private func validationMessage(_ error: MedicationScheduleEntryRules.ValidationError) -> String {
        switch error {
        case .empty: return L10n.planFormSlotMissing
        case .invalidTime: return L10n.planFormCustomTimesInvalid
        case .duplicateTime: return L10n.planFormSlotDuplicate
        case .duplicateSlot: return L10n.planFormSlotDuplicate
        case .invalidRange: return L10n.planFormRangeInvalid
        }
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color("semantic-danger", bundle: .main))
    }

    private func seed() {
        guard case .edit(let row) = mode, name.isEmpty, selectedSlots.isEmpty,
              slotTimeTexts.isEmpty, customEntries.isEmpty else { return }
        name = row.name ?? ""
        // 条目模型优先；旧的仅 times 行（v42）按时段默认时刻认领，其余自定义。
        let seeded = row.entries.isEmpty
            ? MedicationScheduleEntryRules.entries(fromLegacyTimes: row.times)
            : row.entries
        for entry in seeded {
            if let slot = entry.slot {
                selectedSlots.insert(slot)
                slotTimeTexts[slot] = entry.time
                if let start = entry.rangeStart, let end = entry.rangeEnd {
                    slotRangeTexts[slot] = [start, end]
                }
            } else {
                customEntries.append(entry)
            }
        }
        // 编辑态绝不默认勾选（旧 seed 会给纯自定义模板强塞早餐前 → 静默多一剂）。
        // 仅新建表单给一个可执行的起点。
        if !isEditing && selectedSlots.isEmpty && customEntries.isEmpty {
            selectedSlots = [.beforeBreakfast]
        }
    }

    private func save() {
        guard let schedules else { return }
        guard validationError == nil else { return }
        isSaving = true
        let normalized = entries
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName: String? = trimmed.isEmpty ? nil : trimmed
        Task {
            do {
                switch mode {
                case .create:
                    try await schedules.create(patientId: app.currentPatientId,
                                               name: displayName, entries: normalized)
                case .edit(let row):
                    try await schedules.update(id: row.id, name: displayName,
                                               entries: normalized)
                }
                await onSaved()
                dismiss()
            } catch {
                saveFailed = true
                isSaving = false
            }
        }
    }

    // MARK: 绑定

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

    private func rangeBinding(_ slot: DoseTimeSlot, isStart: Bool) -> Binding<Date> {
        let range = effectiveRange(slot)
        let time = isStart ? range.start : range.end
        return Binding(
            get: { DoseTimeSlotRules.date(for: time) ?? Date() },
            set: { date in
                var texts = slotRangeTexts[slot] ?? [range.start, range.end]
                let value = DoseTimeSlotRules.timeString(from: date)
                if isStart { texts[0] = value } else { texts[1] = value }
                slotRangeTexts[slot] = texts
            })
    }

    private func timeBinding(_ text: Binding<String>,
                             fallback: String = "08:00") -> Binding<Date> {
        Binding(
            get: { DoseTimeSlotRules.date(for: text.wrappedValue.isEmpty ? fallback : text.wrappedValue) ?? Date() },
            set: { text.wrappedValue = DoseTimeSlotRules.timeString(from: $0) })
    }

    /// 自定义条目的范围绑定：两侧可空；用户先动任一端时自动补齐另一端
    /// （`validate` 要求范围两端齐全，半截范围会被拒绝）。
    private func customRangeBinding(_ entry: Binding<MedicationScheduleEntry>,
                                    isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                let value = isStart ? entry.wrappedValue.rangeStart : entry.wrappedValue.rangeEnd
                return DoseTimeSlotRules.date(for: value ?? entry.wrappedValue.time) ?? Date()
            },
            set: { date in
                let value = DoseTimeSlotRules.timeString(from: date)
                var copy = entry.wrappedValue
                if copy.rangeStart == nil || copy.rangeEnd == nil {
                    let startMin = DoseScheduleEngine.minutes(value) ?? 0
                    let endMin = min(startMin + 30, 24 * 60 - 1)
                    let end = String(format: "%02d:%02d", endMin / 60, endMin % 60)
                    copy.rangeStart = isStart ? value : (copy.rangeStart ?? value)
                    copy.rangeEnd = isStart ? end : value
                } else if isStart {
                    copy.rangeStart = value
                } else {
                    copy.rangeEnd = value
                }
                entry.wrappedValue = copy
            })
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
    @State private var showDeleteConfirm = false

    var body: some View {
        WithPerceptionTracking {
            List {
                Section(L10n.planFormSlots) {
                    ForEach(template.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.slot?.localizedTitle ?? entry.time)
                                .font(.subheadline)
                            if let range = MedicationScheduleEntryRules.range(of: entry) {
                                Text(L10n.planFormRangeFmt(range.start, range.end))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if entry.slot != nil {
                                Text(entry.time).font(.body.monospacedDigit())
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("SP-15.schedule.detail.entry.\(entry.id)")
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
                    Button(L10n.planScheduleDelete, role: .destructive) { showDeleteConfirm = true }
                        .accessibilityIdentifier("SP-15.schedule.delete")
                }
                .confirmationDialog(L10n.planScheduleDelete, isPresented: $showDeleteConfirm,
                                    titleVisibility: .visible) {
                    Button(L10n.planScheduleDelete, role: .destructive) { delete() }
                    Button(L10n.commonCancel, role: .cancel) { }
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


// MARK: - 路由入口（深链/首页卡片「新建用药计划」）

/// 按 id 加载模板后进入编辑；无 id 直接进入新建。
struct MedicationScheduleFormRouteView: View {
    @Environment(\.medicationScheduleStore) private var schedules
    let templateId: UUID?

    @State private var loaded: MedicationScheduleStore.TemplateRow?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let templateId {
                if let loaded {
                    MedicationScheduleFormView(mode: .edit(loaded)) { }
                } else if loadFailed {
                    VStack(spacing: 12) {
                        Text(L10n.planScheduleLoadFailed)
                            .foregroundStyle(Color("semantic-danger", bundle: .main))
                        Button(L10n.retry) { Task { await load() } }
                    }
                } else {
                    ProgressView().task { await load() }
                }
            } else {
                MedicationScheduleFormView(mode: .create) { }
            }
        }
    }

    private func load() async {
        guard let templateId, let schedules else { return }
        do {
            loaded = try await schedules.template(id: templateId)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }
}
