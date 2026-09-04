import SwiftUI
import Domain

/// F11/SP-10 文档详情（5.6 的 M1a 切片）：识别字段 + 修订历史 + 导出。
/// 评审修正：此前时间轴条目无详情路由（样张处方点不开）且无导出入口——
/// 本视图补两者：行 push 进入，工具栏 ShareLink 导出纯文本摘要
/// （仅 C 级确认文本，不含任何敏感媒体，BR-007/008 不适用）。
struct TimelineDocumentDetailView: View {
    @Environment(AppState.self) private var app
    let entry: TimelineDocumentEntry

    var body: some View {
        List {
            Section(L10n.docTitleSection) {
                // 导航栏已是「文档详情」，行内不再重复标题标签，直接呈现条目名
                Text(entry.title).font(.headline)
                LabeledContent(L10n.docDate, value: occurredDateText)
            }
            Section(L10n.docFieldsSection) {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.displayLabel)
                            .font(.caption)
                            .foregroundStyle(Color("text-secondary", bundle: .main))
                        Text(field.value).font(.body)
                        Text(field.isConfirmed ? L10n.onboard_confirmed : L10n.onboard_unconfirmedBadge)
                            .font(.caption2)
                            .foregroundStyle(field.isConfirmed
                                ? Color("grade-c", bundle: .main)
                                : Color("grade-d", bundle: .main))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("SP-10.document.field.\(field.key)")
                }
            }
            if !entry.revisionHistory.isEmpty {
                Section(L10n.docHistorySection) {
                    ForEach(entry.revisionHistory, id: \.self) { item in
                        Text(item).font(.caption)
                    }
                }
            }
        }
        .navigationTitle(L10n.docDetailTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // 导出入口（评审修正）：纯文本摘要，ShareLink 走系统分享面板；
                // 审计（§7 七动作之一）随点击落 audit_event（未注入审计时静默跳过）
                ShareLink(item: exportText) {
                    Label(L10n.docExport, systemImage: "square.and.arrow.up")
                }
                .simultaneousGesture(TapGesture().onEnded {
                    app.auditExport(documentId: entry.id, title: entry.title)
                })
                .accessibilityIdentifier("SP-10.document.export")
            }
            // FR6.7 报告识别问题（本地记录，P1 进审核后台）
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    app.reportRecognitionIssue(documentId: entry.id)
                } label: {
                    Image(systemName: "exclamationmark.bubble")
                }
                .accessibilityLabel(L10n.docReportIssue)
                .accessibilityIdentifier("SP-53.document.reportIssue")
            }
        }
    }

    private var occurredDate: Date { Date(timeIntervalSince1970: entry.occurredAt) }
    private var occurredDateText: String { occurredDate.formatted(date: .abbreviated, time: .shortened) }
    private var fields: [CandidateField] { entry.fields ?? [] }

    /// 纯文本导出：标题 + 时间 + 字段（名称: 值）+ 修订历史。
    /// 不含任何媒体资产引用（BR-007/008：敏感媒体永不出分享面板）。
    private var exportText: String {
        var lines: [String] = [entry.title, occurredDateText]
        for field in fields {
            lines.append("\(field.displayLabel): \(field.value)")
        }
        if !entry.revisionHistory.isEmpty {
            lines.append(entry.revisionHistory.joined(separator: " → "))
        }
        return lines.joined(separator: "\n")
    }
}
