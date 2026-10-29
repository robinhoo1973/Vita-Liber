import SwiftUI

/// 出生日期轮盘选择（2026-10-29 业主：iPad Pro 9.7 上 Form 内联日期选择器无法滚动，
/// 只能手输年月日）。实现纪律：轮盘放在**独立 sheet** 内（Form/List 内的内联
/// Picker 在 iPad 上会被表述层接管，滚轮不可滚——本轮问题的直接病因），
/// `.wheel` 样式 + 44pt 行；选择器自身保证日期合法（不存在 2023-02-30）。
struct BirthDateWheelSheet: View {
    /// 允许「只记录年份」（FR3.1 精度纪律：年份必填、月日可空）。
    var allowYearOnly: Bool
    @Binding var year: String
    @Binding var month: String
    @Binding var day: String
    /// 最早可选（Domain 单一出口传入）。
    var earliest: Date
    var latest: Date = Date()
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var yearOnly: Bool

    init(allowYearOnly: Bool, year: Binding<String>, month: Binding<String>, day: Binding<String>,
         earliest: Date, latest: Date = Date()) {
        self.allowYearOnly = allowYearOnly
        _year = year
        _month = month
        _day = day
        self.earliest = earliest
        self.latest = latest
        // 初值：完整年月日可解析→用之；仅年份→该年 1 月 1 日；否则今天。
        var initial = Date()
        let y = year.wrappedValue, m = month.wrappedValue, d = day.wrappedValue
        if y.count == 4, let yi = Int(y) {
            if m.count >= 1, d.count >= 1, let mi = Int(m), let di = Int(d),
               let parsed = Calendar(identifier: .gregorian)
                   .date(from: DateComponents(year: yi, month: mi, day: di)) {
                initial = parsed
            } else {
                initial = Calendar(identifier: .gregorian)
                    .date(from: DateComponents(year: yi, month: 1, day: 1)) ?? Date()
            }
        }
        _date = State(initialValue: min(max(initial, earliest), latest))
        _yearOnly = State(initialValue: allowYearOnly && y.count == 4
                          && (m.isEmpty || d.isEmpty))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                DatePicker(L10n.member_birthDateLabel, selection: $date,
                           in: earliest...latest, displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("birthDate.wheel")
                    .opacity(yearOnly ? 0.35 : 1)
                    .allowsHitTesting(!yearOnly)
                if allowYearOnly {
                    Toggle(L10n.birthDateYearOnly, isOn: $yearOnly)
                        .frame(maxWidth: 320)
                        .accessibilityIdentifier("birthDate.yearOnly")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .navigationTitle(L10n.member_birthDateLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonConfirm) {
                        apply()
                        dismiss()
                    }
                    .accessibilityIdentifier("birthDate.confirm")
                }
            }
        }
    }

    private func apply() {
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day], from: date)
        guard let y = components.year else { return }
        year = String(format: "%04d", y)
        if yearOnly {
            month = ""
            day = ""
        } else {
            month = String(format: "%02d", components.month ?? 1)
            day = String(format: "%02d", components.day ?? 1)
        }
    }
}

/// Date 绑定版轮盘（成员新建/成员详情补录共用；与字符串版同一 .wheel 纪律：
/// 独立 sheet、不放进 Form/List 内联——iPad 表述层接管导致轮盘不可滚）。
struct BirthDateDateSheet: View {
    @Binding var date: Date
    var earliest: Date
    var latest: Date = Date()
    var onPicked: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var working: Date

    init(date: Binding<Date>, earliest: Date, latest: Date = Date(), onPicked: @escaping () -> Void = {}) {
        _date = date
        self.earliest = earliest
        self.latest = latest
        self.onPicked = onPicked
        _working = State(initialValue: min(max(date.wrappedValue, earliest), latest))
    }

    var body: some View {
        NavigationStack {
            VStack {
                DatePicker(L10n.member_birthDateLabel, selection: $working,
                           in: earliest...latest, displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("birthDate.wheel")
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .navigationTitle(L10n.member_birthDateLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonConfirm) {
                        date = working
                        onPicked()
                        dismiss()
                    }
                    .accessibilityIdentifier("birthDate.confirm")
                }
            }
        }
    }
}
