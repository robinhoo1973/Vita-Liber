import SwiftUI
import Domain
import Infrastructure

/// FR4.5/FR4.6 疫苗接种记录（SP-54）：手动录入 + 来源/确认状态徽章。
///
/// 边界（FR4.6）：只如实记录，**不提供接种建议、不判定漏种责任、
/// 不内置免疫计划判定**——「下一剂次」仅是序号提示，计划与提醒由用户登记。
struct ImmunizationListView: View {
    let records: [ImmunizationStore.Record]
    let patientId: UUID
    var birthDate: String?
    var sex: String?
    var onCreate: ((String, Int, Date?, String, String) -> Void)?
    @State private var showCreate = false
    @State private var showSchedule = false

    /// 按疫苗名分组（保序：首次出现顺序）
    private var groupedRecords: [(name: String, records: [ImmunizationStore.Record])] {
        var order: [String] = []
        var map: [String: [ImmunizationStore.Record]] = [:]
        for r in records {
            if map[r.vaccineName] == nil { order.append(r.vaccineName) }
            map[r.vaccineName, default: []].append(r)
        }
        return order.map { (name: $0, records: map[$0] ?? []) }
    }

    var body: some View {
        List {
            if records.isEmpty {
                VLUnavailableView(L10n.immunization_empty, systemImage: "syringe",
                                       description: Text(L10n.immunization_emptyHint))
                    .accessibilityIdentifier("FR4.5.immunization.empty")
            } else {
                // §5.31 按疫苗分组 + 剂次进度（V3.72）：已接 n 剂；应接 N 由用户登记
                //（本版以「已接剂次数」呈现，不判定漏种——FR4.6 边界）
                ForEach(groupedRecords, id: \.name) { group in
                    Section {
                        ForEach(group.records) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(L10n.doseNumber(record.doseNumber)).font(.subheadline)
                                    Spacer()
                                    GradeBadge(grade: record.confirmed ? "C" : "D")
                                }
                                Text(record.administeredAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
                                    .font(.caption).foregroundStyle(.secondary)
                                if !record.provider.isEmpty || !record.lotNumber.isEmpty {
                                    Text("\(record.provider)\(record.lotNumber.isEmpty ? "" : L10n.immunizationLot(record.lotNumber))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("FR4.5.immunization.row")
                        }
                    } header: {
                        LabeledContent(L10n.immunizationDoseCount(group.records.count)) {
                            Text(group.name)
                        }
                    }
                }
                // L3 常驻微文案（§5.31）；程序参考入口在工具栏，不在此处判定漏种。
                Section {
                    Text(L10n.immunization_note)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
        .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
        .navigationTitle(L10n.immunization_title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showSchedule = true
                } label: {
                    Label(L10n.immunizationScheduleTitle,
                          systemImage: "calendar.badge.clock")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("FR4.5.immunization.schedule")
                Button {
                    showCreate = true
                } label: {
                    Label(L10n.commonAdd, systemImage: "plus.circle").frame(minHeight: 44)
                }
                .accessibilityIdentifier("FR4.5.immunization.add")
            }
        }
        .sheet(isPresented: $showCreate) {
            ImmunizationCreateSheet { name, dose, date, provider, lot in
                onCreate?(name, dose, date, provider, lot)
                showCreate = false
            }
        }
        .sheet(isPresented: $showSchedule) {
            ImmunizationScheduleView(birthDate: birthDate, sex: sex) { name, dose, date, provider, lot in
                onCreate?(name, dose, date, provider, lot)
                showSchedule = false
            }
        }
    }
}

// 第八轮全仓审查修复（GradeBadge 唯一渲染出口）：原 GradeBadgeText 手写
// Capsule 徽章变体——GradeBadge.swift 文档明令「全仓唯一渲染出口，禁止
// 视图手写 Capsule 徽章变体」（V3.72 五态统一；第四轮已在 EncounterViews/
// MedicationPlanViews/PendingOcrQueueView 删除同款手写变体）。已改用
// GradeBadge(grade: confirmed ? "C" : "D") 并删除本结构。

private struct ImmunizationCreateSheet: View {
    let onCreate: (String, Int, Date?, String, String) -> Void
    @State private var name = ""
    @State private var dose = 1
    @State private var date: Date? = Date()
    @State private var provider = ""
    @State private var lot = ""

    init(initialName: String = "", initialDose: Int = 1,
         onCreate: @escaping (String, Int, Date?, String, String) -> Void) {
        self.onCreate = onCreate
        _name = State(initialValue: initialName)
        _dose = State(initialValue: max(1, initialDose))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.immunizationVaccineName, text: $name)
                    .accessibilityIdentifier("FR4.5.create.name")
                Stepper(L10n.doseNumber(dose), value: $dose, in: 1...20)
                    .accessibilityIdentifier("FR4.5.create.dose")
                DatePicker(L10n.immunizationDate, selection: Binding(
                    get: { date ?? Date() },
                    set: { date = $0 }))
                TextField(L10n.immunizationProvider, text: $provider)
                    .accessibilityIdentifier("FR4.5.create.provider")
                TextField(L10n.immunizationLotField, text: $lot)
                    .accessibilityIdentifier("FR4.5.create.lot")
                Text(L10n.immunization_note)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle(L10n.immunizationCreateTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonSave) { onCreate(name, dose, date, provider, lot) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("FR4.5.create.save")
                }
            }
        }
    }
}

// MARK: - 按年龄/性别选择疫苗（2026-10-22 业主）

/// 从内置官方程序参考目录选择疫苗，按当前成员年龄/性别过滤。
/// 只做记录入口，不判定漏种、不提供接种建议（FR4.6 边界）。
struct ImmunizationScheduleView: View {
    let birthDate: String?
    let sex: String?
    let onCreate: (String, Int, Date?, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var includeAllAges = false
    @State private var query = ""
    @State private var selected: VaccineCatalog.Item?

    private var ageMonths: Int? {
        VaccineCatalog.ageMonths(birthDate: birthDate)
    }

    private var filtered: [VaccineCatalog.Item] {
        let base = VaccineCatalog.items(ageMonths: ageMonths, sex: sex,
                                        includeAllAges: includeAllAges)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.disease.localizedCaseInsensitiveContains(q)
        }
    }

    private var national: [VaccineCatalog.Item] {
        filtered.filter { $0.category == .national }
    }

    private var optional: [VaccineCatalog.Item] {
        filtered.filter { $0.category == .optional }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.immunizationScheduleHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if ageMonths == nil {
                        Text(L10n.immunizationAgeUnknown)
                            .font(.caption)
                            .foregroundStyle(Color("semantic-warning", bundle: .main))
                    }
                    Toggle(isOn: Binding(
                        get: { !includeAllAges },
                        set: { includeAllAges = !$0 }
                    )) {
                        Text(L10n.immunizationOnlyAge)
                    }
                    .disabled(ageMonths == nil)
                    .accessibilityIdentifier("FR4.5.schedule.onlyAge")
                }

                if !national.isEmpty {
                    Section(L10n.immunizationSectionNational) {
                        ForEach(national) { item in
                            row(item)
                        }
                    }
                }
                if !optional.isEmpty {
                    Section(L10n.immunizationSectionOptional) {
                        ForEach(optional) { item in
                            row(item)
                        }
                    }
                }
                if filtered.isEmpty {
                    Text(L10n.immunizationEmptyFiltered)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("FR4.5.schedule.empty")
                }

                Section {
                    Text(L10n.immunizationSourceNote)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .searchable(text: $query, prompt: L10n.immunizationSearchPrompt)
            .navigationTitle(L10n.immunizationScheduleTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonClose) { dismiss() }
                        .accessibilityIdentifier("FR4.5.schedule.close")
                }
            }
        }
        .sheet(item: $selected) { item in
            ImmunizationCreateSheet(initialName: item.name,
                                    initialDose: item.doseNumber) { name, dose, date, provider, lot in
                onCreate(name, dose, date, provider, lot)
                selected = nil
                dismiss()
            }
        }
    }

    private func row(_ item: VaccineCatalog.Item) -> some View {
        Button {
            selected = item
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline)
                    Text("\(item.disease) · \(L10n.doseNumber(item.doseNumber))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .foregroundStyle(Color("brand-primary", bundle: .main))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("FR4.5.schedule.item.\(item.id)")
    }
}
