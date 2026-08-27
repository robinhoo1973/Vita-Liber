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

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView(L10n.immunization_empty, systemImage: "syringe",
                                       description: Text(L10n.immunization_emptyHint))
                    .accessibilityIdentifier("FR4.5.immunization.empty")
            } else {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(record.vaccineName).font(.headline)
                            Spacer()
                            GradeBadgeText(confirmed: record.confirmed)
                        }
                        Text(L10n.doseNumber(record.doseNumber)
                             + (record.administeredAt.map { " · \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                            .font(.subheadline).foregroundStyle(.secondary)
                        if !record.provider.isEmpty || !record.lotNumber.isEmpty {
                            Text("\(record.provider)\(record.lotNumber.isEmpty ? "" : " · 批号 \(record.lotNumber)")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("FR4.5.immunization.row")
                }
            }
        }
        .navigationTitle(L10n.immunization_title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreate = true
                } label: {
                    Label(L10n.claim_add, image: "ic-add").frame(minHeight: 44)
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

/// 确认状态徽章：C 级已确认实心 / D 级待确认虚线（BR-003）
private struct GradeBadgeText: View {
    let confirmed: Bool
    var body: some View {
        Text(confirmed ? L10n.immunization_confirmed : L10n.immunization_pending)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color("surface-tint-start", bundle: .main)))
            .overlay(Capsule().strokeBorder(
                confirmed ? Color("brand-primary", bundle: .main) : Color("grade-d", bundle: .main),
                style: StrokeStyle(lineWidth: 1, dash: confirmed ? [] : [3, 2])))
            .foregroundStyle(confirmed ? Color("brand-primary", bundle: .main) : Color("grade-d", bundle: .main))
            .accessibilityLabel(confirmed ? L10n.onboard_sourceConfirmed : L10n.onboard_unconfirmed2)
    }
}

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
                TextField("疫苗名称", text: $name)
                    .accessibilityIdentifier("FR4.5.create.name")
                Stepper(L10n.doseNumber(dose), value: $dose, in: 1...20)
                    .accessibilityIdentifier("FR4.5.create.dose")
                DatePicker("接种日期", selection: Binding(
                    get: { date ?? Date() },
                    set: { date = $0 }))
                TextField("接种机构", text: $provider)
                    .accessibilityIdentifier("FR4.5.create.provider")
                TextField("批号", text: $lot)
                    .accessibilityIdentifier("FR4.5.create.lot")
                Text(L10n.immunization_note)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("新增疫苗记录")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onCreate(name, dose, date, provider, lot) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("FR4.5.create.save")
                }
            }
        }
    }
}
