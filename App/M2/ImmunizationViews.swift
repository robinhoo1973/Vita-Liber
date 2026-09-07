import SwiftUI
import Infrastructure

/// FR4.5/FR4.6 疫苗接种记录（SP-54）：手动录入 + 来源/确认状态徽章。
///
/// 边界（FR4.6）：只如实记录，**不提供接种建议、不判定漏种责任、
/// 不内置免疫计划判定**——「下一剂次」仅是序号提示，计划与提醒由用户登记。
struct ImmunizationListView: View {
    let records: [ImmunizationStore.Record]
    let patientId: UUID
    var onCreate: ((String, Int, Date?, String, String) -> Void)?
    @State private var showCreate = false

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
                ContentUnavailableView(L10n.immunization_empty, systemImage: "syringe",
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
                // L3 常驻微文案 + 儿童免疫计划置灰占位（§5.31）
                Section {
                    Text(L10n.immunization_note)
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(L10n.immunization_childPlanComing)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .navigationTitle(L10n.immunization_title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreate = true
                } label: {
                    Label(L10n.claim_add, systemImage: "plus.circle").frame(minHeight: 44)
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
