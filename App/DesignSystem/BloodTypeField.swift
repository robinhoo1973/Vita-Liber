import SwiftUI

/// 血型选择（2026-10-29 业主：原「ABO 一行 push buttons + Rh 一行」两步网格排布混乱；
/// 多角色讨论结论 = 单一决策点、系统原生单列表）。
///
/// 设计依据（同类产品对照，见讨论稿 2026-10-29-first-launch-fixes-round1）：
/// - Apple 健康「医疗急救卡」血型 = 表单行 → 单列列表单选（A+/A−/…/未知），一次决策；
/// - MyChart / 多数医院 App 同为「行 + 列表」而非多组按钮；
/// - 两步网格（先 ABO 后 Rh）强迫两次点按且 Rh 未选 ABO 前禁用，语义断链。
///
/// 值编码与旧组件完全一致（A / B / AB / O / A+ / A− / unknown / special…），
/// 存量患者档案零迁移；测试用静态纯函数保留在此（单一出处）。
struct BloodTypeField: View {
    @Binding var selection: String
    @State private var showPicker = false

    private static let abo = ["A", "B", "AB", "O"]
    private static let standard: [String] = abo.flatMap { [$0 + "+", $0 + "−"] }
    /// 稳定哨兵：不把本地化显示文案写进患者档案。
    static let unknownValue = "unknown"

    static func aboValue(from selection: String) -> String? {
        abo.first { value in
            selection == value || selection == value + "+" || selection == value + "−"
        }
    }

    static func rhValue(from selection: String) -> String? {
        if selection.hasSuffix("+") { return "+" }
        if selection.hasSuffix("−") { return "−" }
        return nil
    }

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack {
                Text(L10n.bloodTypeLabel)
                    .foregroundStyle(Color("text-primary", bundle: .main))
                Spacer(minLength: 8)
                Text(displayText)
                    .foregroundStyle(selection.isEmpty
                        ? Color("text-secondary", bundle: .main)
                        : Color("brand-primary", bundle: .main))
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color("text-tertiary", bundle: .main))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bloodType.select")
        .sheet(isPresented: $showPicker) {
            BloodTypePickerSheet(selection: $selection)
        }
    }

    private var displayText: String {
        if selection.isEmpty { return L10n.onboardNotSelected }
        if selection == Self.unknownValue { return L10n.bloodTypeUnknown }
        if selection == "special" { return L10n.onboardBloodSpecial }
        return selection
    }
}

private struct BloodTypePickerSheet: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    private var options: [(value: String, title: String, id: String)] {
        var rows: [(String, String, String)] = BloodTypeField.standard.map {
            ($0, $0, "bloodType.option." + $0.replacingOccurrences(of: "+", with: "pos")
                .replacingOccurrences(of: "−", with: "neg"))
        }
        rows.append((BloodTypeField.unknownValue, L10n.bloodTypeUnknown, "bloodType.option.unknown"))
        rows.append(("special", L10n.onboardBloodSpecial, "bloodType.option.special"))
        return rows
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(options, id: \.id) { option in
                        Button {
                            selection = option.value
                            dismiss()
                        } label: {
                            HStack {
                                Text(option.title)
                                    .foregroundStyle(Color("text-primary", bundle: .main))
                                Spacer(minLength: 8)
                                if selection == option.value {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color("brand-primary", bundle: .main))
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(option.id)
                        .accessibilityAddTraits(selection == option.value ? .isSelected : [])
                    }
                } footer: {
                    Text(L10n.bloodTypePickerFooter)
                }
            }
            .navigationTitle(L10n.bloodTypeLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
            }
        }
    }
}
