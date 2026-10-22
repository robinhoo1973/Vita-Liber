import SwiftUI

/// 血型 push button 选择（ABO 一行 + Rh 一行 + 不知道/特殊）。
/// 不使用 Picker；选中态为品牌色实心，未选为玻璃底描边，触点 ≥44pt。
struct BloodTypePushGrid: View {
    @Binding var selection: String

    private static let abo = ["A", "B", "AB", "O"]
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

    private var currentABO: String? { Self.aboValue(from: selection) }

    private var currentRh: String? { Self.rhValue(from: selection) }

    private var unknownSelected: Bool {
        selection == Self.unknownValue || selection == L10n.bloodTypeUnknown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.bloodTypeABO)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                      spacing: 8) {
                ForEach(Self.abo, id: \.self) { value in
                    button(title: value, selected: currentABO == value) {
                        let rh = currentRh ?? ""
                        selection = value + rh
                    }
                    .accessibilityIdentifier("bloodType.abo.\(value)")
                }
            }

            Text(L10n.bloodTypeRh)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                      spacing: 8) {
                button(title: L10n.bloodTypePositive, selected: currentRh == "+") {
                    guard let abo = currentABO else { return }
                    selection = abo + "+"
                }
                .disabled(currentABO == nil)
                .accessibilityIdentifier("bloodType.rh.positive")
                button(title: L10n.bloodTypeNegative, selected: currentRh == "−") {
                    guard let abo = currentABO else { return }
                    selection = abo + "−"
                }
                .disabled(currentABO == nil)
                .accessibilityIdentifier("bloodType.rh.negative")
                button(title: L10n.bloodTypeRhUnknown, selected: currentABO != nil && currentRh == nil) {
                    guard let abo = currentABO else { return }
                    selection = abo
                }
                .disabled(currentABO == nil)
                .accessibilityIdentifier("bloodType.rh.unknown")
            }

            HStack(spacing: 8) {
                button(title: L10n.bloodTypeUnknown, selected: unknownSelected) {
                    selection = Self.unknownValue
                }
                .accessibilityIdentifier("bloodType.unknown")
                button(title: L10n.onboardBloodSpecial, selected: selection == "special") {
                    selection = "special"
                }
                .accessibilityIdentifier("bloodType.special")
            }
        }
    }

    private func button(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(BloodTypeChipStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct BloodTypeChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.white : Color("text-primary", bundle: .main))
            .background(
                selected ? Color("brand-primary", bundle: .main)
                         : Color("bg-grouped", bundle: .main),
                in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.clear : Color("text-primary", bundle: .main).opacity(0.10),
                            lineWidth: 1))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}
