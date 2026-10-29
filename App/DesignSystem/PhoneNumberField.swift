import SwiftUI
import Domain
import Perception

/// 电话号码字段（2026-10-29 业主）：国家/地区区号选择（名称 + 国旗）+ 九宫数字键盘。
/// 存储形态 = `PhoneCountryCatalog.canonical`（`+<dial><digits>`）；旧存量无前缀
/// 纯数字按默认地区（CN）解析展示。联系人/紧急联系人共用本组件。
struct PhoneNumberField: View {
    /// 存储权威串（只写规范化形态；父表单校验仍走 Domain `validPhone`）。
    @Binding var phone: String
    var label: String
    /// 无障碍标识前缀（行/按钮/输入框分别追加 .country / .number）。
    var identifierPrefix: String

    @State private var region = PhoneCountryCatalog.defaultRegion
    @State private var national = ""
    @State private var showCountryPicker = false
    @State private var didLoad = false
    @FocusState private var numberFocused: Bool

    private var dial: String {
        PhoneCountryCatalog.dialCodeByRegion[region] ?? "86"
    }

    private var locale: Locale { Locale(identifier: L10n.bundleLanguage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    showCountryPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text(PhoneCountryCatalog.flag(region))
                        Text("+\(dial)")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(PhoneCountryCatalog.displayName(region, locale: locale)) +\(dial)")
                .accessibilityIdentifier("\(identifierPrefix).country")

                TextField(label, text: $national, prompt: Text(label))
                    .keyboardType(.numberPad)
                    .focused($numberFocused)
                    .monospacedDigit()
                    .accessibilityIdentifier("\(identifierPrefix).number")
                    .onChangeCompat(of: national) { _, newValue in
                        syncFromField(newValue)
                    }
            }
        }
        .onAppear { loadFromPhoneIfNeeded() }
        .onChangeCompat(of: phone) { _, _ in loadFromPhoneIfNeeded(force: true) }
        .sheet(isPresented: $showCountryPicker) {
            CountryPickerSheet(selected: $region, locale: locale)
                .onDisappear { rebuildCanonical() }
        }
    }

    private func loadFromPhoneIfNeeded(force: Bool = false) {
        if didLoad && !force { return }
        didLoad = true
        let parsed = PhoneCountryCatalog.parse(phone)
        // 仅当外部值与当前推导一致时不打断输入（避免父视图回写抖动）。
        region = parsed.region
        national = Self.formatted(parsed.nationalDigits)
    }

    /// 输入过滤：只留数字并分组显示；任何非数字（含粘贴 + 前缀）剥除。
    private func syncFromField(_ value: String) {
        let digits = String(value.filter(\.isNumber).prefix(15))
        let formatted = Self.formatted(digits)
        if value != formatted { national = formatted }
        rebuildCanonical()
    }

    private func rebuildCanonical() {
        let digits = national.filter(\.isNumber)
        let canonical = PhoneCountryCatalog.canonical(region: region, nationalDigits: digits)
        if phone != canonical { phone = canonical }
    }

    /// 通用分组：3-4-4，其后每 4 位一组（138 0013 8000 / 555 123 4567）。
    static func formatted(_ digits: String) -> String {
        guard !digits.isEmpty else { return "" }
        var groups: [String] = []
        var index = digits.startIndex
        var size = 3
        var first = true
        while index < digits.endIndex {
            let end = digits.index(index, offsetBy: size, limitedBy: digits.endIndex) ?? digits.endIndex
            groups.append(String(digits[index..<end]))
            index = end
            if first { size = 4; first = false }
        }
        return groups.joined(separator: " ")
    }
}

/// 国家/地区选择（搜索：本地化地区名或拨号码；行=国旗+名称+区号）。
private struct CountryPickerSheet: View {
    @Binding var selected: String
    let locale: Locale
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Row: Identifiable {
        let region: String
        let name: String
        let dial: String
        var id: String { region }
    }

    private var rows: [Row] {
        PhoneCountryCatalog.allRegions.compactMap { region in
            guard let dial = PhoneCountryCatalog.dialCodeByRegion[region] else { return nil }
            return Row(region: region,
                       name: PhoneCountryCatalog.displayName(region, locale: locale),
                       dial: dial)
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private var filtered: [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rows }
        let needle = trimmed.replacingOccurrences(of: "+", with: "")
        return rows.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.dial.hasPrefix(needle)
                || $0.region.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { row in
                Button {
                    selected = row.region
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Text(PhoneCountryCatalog.flag(row.region))
                            .font(.title3)
                            .accessibilityHidden(true)
                        Text(row.name)
                            .foregroundStyle(Color("text-primary", bundle: .main))
                        Spacer(minLength: 8)
                        Text("+\(row.dial)")
                            .foregroundStyle(Color("text-secondary", bundle: .main))
                            .monospacedDigit()
                        if row.region == selected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color("brand-primary", bundle: .main))
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("phone.country.\(row.region)")
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: Text(L10n.phoneCountrySearch))
            .navigationTitle(L10n.phoneCountryTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
            }
        }
    }
}
