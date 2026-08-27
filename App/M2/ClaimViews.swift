import SwiftUI
import Infrastructure

/// FR13.7 报销票据（SP 系列，ui-ux §5.41 引用）：录入 + 汇总。
/// 汇总只做纯事实求和，**不提供报销建议、不评判是否可报**（FR13.7 边界）。
struct ClaimListView: View {
    let rows: [ClaimStore.ClaimRow]
    let totals: ClaimStore.Totals
    var onCreate: ((String, Double, Date, String, String) -> Void)?
    @State private var showCreate = false

    var body: some View {
        List {
            Section {
                Text(totals.statement)
                    .font(.headline).monospacedDigit()
                    .accessibilityIdentifier("FR13.7.claim.totals")
            }
            if rows.isEmpty {
                ContentUnavailableView("还没有报销票据", systemImage: "doc.text",
                                       description: Text("录入发票/费用/收据，按就诊整理"))
                    .accessibilityIdentifier("FR13.7.claim.empty")
            } else {
                ForEach(rows) { row in
                    HStack {
                        VLIcon.labClipboard.resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading) {
                            Text(typeLabel(row.itemType) + (row.merchant.isEmpty ? "" : " · \(row.merchant)"))
                                .font(.subheadline)
                            Text(row.summary).font(.caption).foregroundStyle(.secondary)
                            Text(row.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text("\(row.amount, specifier: "%.2f") \(row.currency)")
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("FR13.7.claim.row")
                }
            }
        }
        .navigationTitle("报销票据")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreate = true
                } label: {
                    Label("新增", image: "ic-add").frame(minHeight: 44)
                }
                .accessibilityIdentifier("FR13.7.claim.add")
            }
        }
        .sheet(isPresented: $showCreate) {
            ClaimCreateSheet { type, amount, date, merchant, summary in
                onCreate?(type, amount, date, merchant, summary)
                showCreate = false
            }
        }
    }

    private func typeLabel(_ type: String) -> String {
        switch type {
        case "invoice": return "发票"
        case "fee": return "费用"
        default: return "收据"
        }
    }
}

private struct ClaimCreateSheet: View {
    let onCreate: (String, Double, Date, String, String) -> Void
    @State private var type = "invoice"
    @State private var amount = ""
    @State private var date = Date()
    @State private var merchant = ""
    @State private var summary = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $type) {
                    Text("发票").tag("invoice")
                    Text("费用").tag("fee")
                    Text("收据").tag("receipt")
                }
                TextField("金额", text: $amount)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("FR13.7.create.amount")
                DatePicker("日期", selection: $date)
                TextField("机构/商家", text: $merchant)
                    .accessibilityIdentifier("FR13.7.create.merchant")
                TextField("摘要", text: $summary)
                    .accessibilityIdentifier("FR13.7.create.summary")
            }
            .navigationTitle("新增票据")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onCreate(type, Double(amount) ?? 0, date, merchant, summary)
                    }
                    .disabled(Double(amount) == nil)
                    .accessibilityIdentifier("FR13.7.create.save")
                }
            }
        }
    }
}
