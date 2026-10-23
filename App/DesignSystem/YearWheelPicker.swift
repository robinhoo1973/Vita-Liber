import SwiftUI
import Domain

/// 年份滚轮选择器（2026-10-23 业主：手术/慢性病年份改上下滚轮）。
///
/// 范围来自 `HealthProblemRules.yearRange()`——与保存层 `parseYear` 共用
/// 同一事实源，滚轮里永远不会出现会被拒绝的年份（如未来年份）。
/// 本组件只负责选择；「不详」仍由调用方显式控件承担（nil ≠ 未知的隐式猜测）。
struct YearWheelPickerSheet: View {
    @Binding var year: Int?
    @Environment(\.dismiss) private var dismiss

    /// 倒序：近年在上，绝大多数登记一打开即可见。
    private let years: [Int]
    @State private var selection: Int?

    init(year: Binding<Int?>) {
        _year = year
        let range = HealthProblemRules.yearRange()
        years = Array(range.reversed())
        // 初值 = 现状（未选过就是「未设置」）——不以今年冒充用户选择，
        // 只有点[保存]才写回（取消零副作用）。
        _selection = State(initialValue: year.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Picker(L10n.healthHistoryYearTitle, selection: $selection) {
                Text(L10n.problemNotSet).tag(Int?.none)
                ForEach(years, id: \.self) { value in
                    Text(verbatim: String(value)).tag(Optional(value))
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("SP-49.problem.year.wheel")
            .navigationTitle(L10n.healthHistoryYearTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                        .accessibilityIdentifier("SP-49.problem.year.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonSave) {
                        year = selection
                        dismiss()
                    }
                    .accessibilityIdentifier("SP-49.problem.year.confirm")
                }
            }
        }
        .presentationDetents([.height(320)])
    }
}
