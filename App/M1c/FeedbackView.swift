import SwiftUI
import Domain

/// FR22.5 反馈与错误报告（SP-46）：分类为功能问题/OCR错误/引用错误/
/// 疑似危险回答/无障碍问题/其他；默认只附版本、系统、错误码和脱敏日志，
/// 截图、原文或媒体需用户逐项勾选（默认关闭且逐项显示风险）。
/// 提交落审计（feedback 行动）——P0 本地留存，P1 上报。
struct FeedbackView: View {
    @Environment(AppState.self) private var app
    @State private var category = 0
    @State private var detail = ""
    @State private var attachScreenshot = false
    @State private var attachOriginalText = false
    @State private var attachMedia = false
    @State private var submitted = false

    // FR22.5 六类反馈（名称经 L10n 三文件；分类 key 落审计用索引）
    private var categories: [String] { (0..<6).map { L10n.feedbackCategoryName($0) } }

    var body: some View {
        Form {
            Section(L10n.feedbackCategory) {
                Picker(L10n.feedbackCategory, selection: $category) {
                    ForEach(categories.indices, id: \.self) { i in
                        Text(L10n.feedbackCategoryName(i)).tag(i)
                    }
                }
            }
            Section(L10n.feedbackDetail) {
                TextField(L10n.feedbackDetailPlaceholder, text: $detail, axis: .vertical)
                    .lineLimit(4...10)
            }
            // 默认只附版本/系统/错误码/脱敏日志；截图/原文/媒体逐项勾选（默认关）
            Section {
                Toggle(L10n.feedbackAttachScreenshot, isOn: $attachScreenshot)
                Toggle(L10n.feedbackAttachOriginal, isOn: $attachOriginalText)
                Toggle(L10n.feedbackAttachMedia, isOn: $attachMedia)
            } header: {
                Text(L10n.feedbackAttachments)
            } footer: {
                Text(L10n.feedbackAttachmentHint)
            }
            Section {
                Button(L10n.feedbackSubmit) {
                    app.reportFeedback(category: categories[category],
                                       detail: detail,
                                       attachments: [attachScreenshot, attachOriginalText, attachMedia])
                    submitted = true
                }
                .disabled(detail.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("SP-46.feedback.submit")
            }
        }
        .navigationTitle(L10n.feedbackTitle)
        .alert(L10n.feedbackSubmitted, isPresented: $submitted) {
            Button(L10n.onboard_gotIt, role: .cancel) { }
        }
    }
}
