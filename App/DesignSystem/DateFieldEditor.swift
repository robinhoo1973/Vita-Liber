import SwiftUI
import Domain

/// 日期字段编辑器（round5 Q4，业主 2026-09-20 第 4 项：日期用选择框而非文本框）。
///
/// 三处日期编辑面（SP-12 `FieldConfirmRow` / 主卡草稿 `ParentDraftSection` / SP-08 `CardFieldEditSheet`）共用：
/// - 文本真值仍是字段的 `value`（规范 `yyyy-MM-dd`，`EntityCardProjection.canonicalDateText` 单源），选择器只是输入法；
/// - 原值（OCR 原文）可解析 → 选择器初值即该日；不可解析且非空 → 上方提示「识别原文「…」不是有效日期」并保留原文供对照，
///   选择器初值取今天，**不自动改写**原值（不猜）——用户选定才写回；
/// - 写回经 `onChange`（调用方决定 revise / fillByUser / confirm 语义），本组件不持业务规则。
struct DateFieldEditor: View {
    let label: String
    let text: String
    var calendar: Calendar = .current
    let onChange: (String) -> Void

    private var parsed: Date? { EntityCardProjection.parseDate(text, calendar: calendar) }
    private var rawUnparsed: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!trimmed.isEmpty && parsed == nil) ? trimmed : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let raw = rawUnparsed {
                Text(L10n.fieldDateUnparsed(raw))
                    .font(.caption)
                    .foregroundStyle(Color("semantic-warning", bundle: .main))
                    .accessibilityIdentifier("field.date.unparsed")
            }
            DatePicker(label, selection: Binding(get: { parsed ?? Date() }, set: { picked in
                onChange(EntityCardProjection.canonicalDateText(picked, calendar: calendar))
            }), displayedComponents: .date)
            .datePickerStyle(.compact)
            .accessibilityIdentifier("field.date.picker")
        }
    }
}
