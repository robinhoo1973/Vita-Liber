import SwiftUI
import Domain
import Infrastructure
import Perception

// MARK: - 用药时段（2026-10-24 业主：原「用药计划」改名，二层页面提升为单页）
//
// 每成员一份默认时段文档：8 个标准时段恒显示、恒启用，可调提醒时刻与常用提醒
// 范围，并可添加自定义时段。这里只是「一天中的时刻表」；某个药品用其中哪几个
// 时刻，在「用药提醒」里选择。保存时按确认框把跟随的提醒改写到新时刻
// （仅未来未确认剂量；历史与已服记录不动）。

private struct MedicationScheduleStoreKey: EnvironmentKey {
    static let defaultValue: MedicationScheduleStore? = nil
}

extension EnvironmentValues {
    var medicationScheduleStore: MedicationScheduleStore? {
        get { self[MedicationScheduleStoreKey.self] }
        set { self[MedicationScheduleStoreKey.self] = newValue }
    }
}

struct MedicationScheduleView: View {
    @Environment(AppState.self) private var app
    @Environment(\.medicationScheduleStore) private var schedules
    @Environment(ReminderStore.self) private var reminders

    /// 保存成功回调：提醒表单内嵌本页时，返回后据此重载时段列表
    /// （否则表单仍持旧时刻/旧键，保存会把新时段又写回旧时刻）。
    var onSaved: (() -> Void)?

    @State private var row: MedicationScheduleStore.ScheduleRow?
    @State private var slotTimeTexts: [DoseTimeSlot: String] = [:]
    @State private var slotRangeTexts: [DoseTimeSlot: [String]] = [:]
    @State private var customEntries: [MedicationScheduleEntry] = []
    @State private var loadFailed = false
    @State private var saveFailed = false
    @State private var isSaving = false
    @State private var showPropagateConfirm = false
    @State private var savedNotice = false

    private var rawEntries: [MedicationScheduleEntry] {
        var list = DoseTimeSlot.allCases.map { slot -> MedicationScheduleEntry in
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

    private var hasChanges: Bool {
        guard let row else { return false }
        return entries != MedicationScheduleEntryRules.normalize(row.entries)
    }

    private var canSave: Bool {
        // 成员切换竞态：只允许保存与当前成员一致的已装载文档
        // （此前仅判 row != nil——切人后仍可把 A 的时段写进 B）。
        !isSaving && row?.patientId == app.currentPatientId && validationError == nil
    }

    var body: some View {
        WithPerceptionTracking {
            List {
                Section {
                    Text(L10n.planSlotsHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)

                if loadFailed {
                    Section {
                        Text(L10n.planSlotsLoadFailed)
                            .font(.caption)
                            .foregroundStyle(Color("semantic-danger", bundle: .main))
                        Button(L10n.retry) { Task { await load() } }
                    }
                } else if let row {
                    Section {
                        ForEach(DoseTimeSlot.allCases, id: \.self) { slot in
                            slotRow(slot)
                        }
                    } header: {
                        Text(L10n.planSlotsStandard)
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
                        Section { errorText(validationMessage(error)) }
                    }
                    if !outsideRange.isEmpty {
                        Section {
                            Text(L10n.planFormRangeNotice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if saveFailed {
                        Section { errorText(L10n.planFormSaveFailedHint) }
                    }
                    Section {
                        Text(L10n.planSlotsLinkedFmt(row.boundPlanCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section { ProgressView() }
                }
            }
            .frame(maxWidth: 672)
            .navigationTitle(L10n.planSlotsTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonSave) { requestSave() }
                        .disabled(!canSave || !hasChanges)
                        .accessibilityIdentifier("SP-15.schedule.form.save")
                }
            }
            .overlay(alignment: .bottom) {
                if savedNotice {
                    Text(L10n.planSlotsSaved)
                        .font(.caption)
                        .padding(8)
                        .background(.thinMaterial, in: Capsule())
                }
            }
            .task(id: app.currentPatientId) { await load() }
            .confirmationDialog(L10n.planSlotsPropagateTitle, isPresented: $showPropagateConfirm,
                                titleVisibility: .visible) {
                Button(L10n.planSlotsPropagateConfirm) { save(propagate: true) }
                Button(L10n.planSlotsSaveOnly) { save(propagate: false) }
                Button(L10n.commonCancel, role: .cancel) { }
            } message: {
                Text(L10n.planSlotsPropagateBody)
            }
        }
    }

    // MARK: 行

    @ViewBuilder
    private func slotRow(_ slot: DoseTimeSlot) -> some View {
        let range = effectiveRange(slot)
        VStack(alignment: .leading, spacing: 4) {
            Text(slot.localizedTitle)
                .font(.subheadline.weight(.semibold))
            DatePicker(L10n.planFormSlotTimeFmt(slot.localizedTitle),
                       selection: slotTimeBinding(slot),
                       displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("SP-15.schedule.form.slot.time.\(slot.rawValue)")
            Text(L10n.planFormRangeFmt(range.start, range.end))
                .font(.caption)
                .foregroundStyle(Color("text-secondary", bundle: .main))
            if slotRangeTexts[slot] != nil {
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-15.schedule.form.slot.\(slot.rawValue)")
    }

    @ViewBuilder
    private func customEntryRow(_ entry: Binding<MedicationScheduleEntry>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DatePicker(L10n.planFormCustomTime, selection: timeBinding(entry.time),
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

    private func effectiveRange(_ slot: DoseTimeSlot) -> (start: String, end: String) {
        if let texts = slotRangeTexts[slot], texts.count == 2 { return (texts[0], texts[1]) }
        return MedicationScheduleEntryRules.defaultRange(for: slot)
    }

    private func validationMessage(_ error: MedicationScheduleEntryRules.ValidationError) -> String {
        switch error {
        case .empty: return L10n.planFormSlotMissing
        case .invalidTime: return L10n.planFormCustomTimesInvalid
        case .duplicateTime, .duplicateSlot: return L10n.planFormSlotDuplicate
        case .invalidRange: return L10n.planFormRangeInvalid
        }
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color("semantic-danger", bundle: .main))
    }

    private func load() async {
        // 先清空，避免切人后短暂把上一成员的时段当作当前成员可保存内容。
        row = nil
        loadFailed = false
        guard let schedules else {
            // 环境未注入不得表现为永久转圈（生产注入缺失时至少给出可重试错误）。
            loadFailed = true
            return
        }
        do {
            let patientId = app.currentPatientId
            let loaded = try await schedules.ensureDefaultSchedule(patientId: patientId)
            // 装载期间再次切人：丢弃过期结果，下一次 .task(id:) 会重载。
            guard loaded.patientId == app.currentPatientId else { return }
            row = loaded
            seed(loaded)
            loadFailed = false
            saveFailed = false
        } catch {
            loadFailed = true
        }
    }

    private func seed(_ row: MedicationScheduleStore.ScheduleRow) {
        slotTimeTexts = [:]
        slotRangeTexts = [:]
        customEntries = []
        for entry in row.entries {
            if let slot = entry.slot {
                slotTimeTexts[slot] = entry.time
                if let start = entry.rangeStart, let end = entry.rangeEnd {
                    slotRangeTexts[slot] = [start, end]
                }
            } else {
                customEntries.append(entry)
            }
        }
    }

    private func requestSave() {
        guard let row, canSave, row.patientId == app.currentPatientId else { return }
        if row.boundPlanCount > 0 {
            showPropagateConfirm = true
        } else {
            save(propagate: true)
        }
    }

    private func save(propagate: Bool) {
        guard let schedules, let currentRow = row,
              currentRow.patientId == app.currentPatientId else { return }
        guard validationError == nil else { return }
        // 捕获保存目标的成员，防止 Task 执行期间切人后把 A 的时段写进 B。
        let patientId = currentRow.patientId
        isSaving = true
        saveFailed = false
        let normalized = entries
        Task {
            do {
                _ = try await schedules.updateDefaultEntries(
                    patientId: patientId, entries: normalized, propagate: propagate)
                if propagate {
                    // 对账通知：清掉旧 id、按新时刻重排未来提醒。
                    await reminders.refresh(patientId: patientId)
                }
                let updated = try await schedules.defaultSchedule(patientId: patientId)
                guard patientId == app.currentPatientId else {
                    isSaving = false
                    return
                }
                guard let updated else {
                    // 更新成功后文档必须存在；缺失按保存失败处理，
                    // 不保留旧行冒充已保存。
                    saveFailed = true
                    isSaving = false
                    return
                }
                row = updated
                seed(updated)
                onSaved?()
                savedNotice = true
                isSaving = false
                try? await Task.sleep(nanoseconds: 1_500_000_000)   // try?-ok: 提示计时
                savedNotice = false
            } catch {
                saveFailed = true
                isSaving = false
            }
        }
    }

    // MARK: 绑定

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

    private func timeBinding(_ text: Binding<String>) -> Binding<Date> {
        Binding(
            get: { DoseTimeSlotRules.date(for: text.wrappedValue.isEmpty ? "08:00" : text.wrappedValue) ?? Date() },
            set: { text.wrappedValue = DoseTimeSlotRules.timeString(from: $0) })
    }

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
                    // 缺一端时按编辑顺序补另一端：先改起始 → 结束取 +30 分；
                    // 先改结束 → 起始取 -30 分。旧实现把两端都置成同一个值，
                    // 校验恒报 range 非法（先改结束永远存不了）。
                    let anchor = DoseScheduleEngine.minutes(value) ?? 0
                    func fmt(_ mins: Int) -> String {
                        String(format: "%02d:%02d", mins / 60, mins % 60)
                    }
                    if isStart {
                        copy.rangeStart = value
                        if copy.rangeEnd == nil {
                            copy.rangeEnd = fmt(min(anchor + 30, 24 * 60 - 1))
                        }
                    } else {
                        copy.rangeEnd = value
                        if copy.rangeStart == nil {
                            copy.rangeStart = fmt(max(anchor - 30, 0))
                        }
                    }
                } else if isStart {
                    copy.rangeStart = value
                } else {
                    copy.rangeEnd = value
                }
                entry.wrappedValue = copy
            })
    }
}
