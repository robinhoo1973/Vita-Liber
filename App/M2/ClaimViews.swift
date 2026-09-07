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
                // 审查修复：汇总文案经 L10n 组装（原 Infrastructure 硬编码简中）。
                // 金额经 Foundation 货币格式化（与行金额同一 FormatStyle，
                // locale 币符/千分位/小数位）——此前 %.2f 无币符无分组，
                // 同一屏幕两种金额形态。币符由 FormatStyle 产出，模板不再
                // 追加币种代码（此前「¥1,234.56 CNY」双重币符）。
                Text(L10n.claimTotals(totals.itemCount,
                                      totals.totalAmount.formatted(
                                          .currency(code: totals.currency).precision(.fractionLength(2)))))
                    .font(.headline).monospacedDigit()
                    .accessibilityIdentifier("FR13.7.claim.totals")
            }
            if rows.isEmpty {
                ContentUnavailableView(L10n.claim_empty, systemImage: "doc.text",
                                       description: Text(L10n.claim_emptyHint))
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
                        // 第八轮修复：货币金额经 Foundation 货币格式化
                        // （locale 币符/千分位/小数位），替代硬编码 %.2f
                        Text(row.amount.formatted(
                            .currency(code: row.currency).precision(.fractionLength(2))))
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("FR13.7.claim.row")
                }
            }
        }
        .navigationTitle(L10n.claim_title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreate = true
                } label: {
                    Label(L10n.claim_add, systemImage: "plus.circle").frame(minHeight: 44)
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
        case "invoice": return L10n.claim_type_invoice
        case "fee": return L10n.claim_type_fee
        default: return L10n.claim_type_receipt
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
                Picker(L10n.claim_type, selection: $type) {
                    Text(L10n.claim_type_invoice).tag("invoice")
                    Text(L10n.claim_type_fee).tag("fee")
                    Text(L10n.claim_type_receipt).tag("receipt")
                }
                TextField(L10n.claim_amount, text: $amount)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("FR13.7.create.amount")
                DatePicker(L10n.claim_date, selection: $date)
                TextField(L10n.claim_merchant, text: $merchant)
                    .accessibilityIdentifier("FR13.7.create.merchant")
                TextField(L10n.claim_summary, text: $summary)
                    .accessibilityIdentifier("FR13.7.create.summary")
            }
            .navigationTitle(L10n.claim_createTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.claim_save) {
                        onCreate(type, Double(amount) ?? 0, date, merchant, summary)
                    }
                    .disabled(Double(amount) == nil)
                    .accessibilityIdentifier("FR13.7.create.save")
                }
            }
        }
    }
}
