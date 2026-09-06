import SwiftUI
import Domain

/// F11/SP-10 文档详情（5.6 的 M1a 切片）：识别字段 + 修订历史 + 导出。
/// 评审修正：此前时间轴条目无详情路由（样张处方点不开）且无导出入口——
/// 本视图补两者：行 push 进入，工具栏 ShareLink 导出纯文本摘要
/// （仅 C 级确认文本，不含任何敏感媒体，BR-007/008 不适用）。
struct TimelineDocumentDetailView: View {
    @Environment(AppState.self) private var app
    let entry: TimelineDocumentEntry

    @State private var reviseTarget: CandidateField?
    @State private var reviseDraft = ""
    @State private var showOriginal = false
    @State private var showIssueSheet = false

    var body: some View {
        List {
            Section(L10n.docTitleSection) {
                // 导航栏已是「文档详情」，行内不再重复标题标签，直接呈现条目名
                Text(L10n.docTitle(entry.title)).font(.headline)
                LabeledContent(L10n.docDate, value: occurredDateText)
            }
            Section(L10n.docFieldsSection) {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.displayLabel)
                            .font(.caption)
                            .foregroundStyle(Color("text-secondary", bundle: .main))
                        Text(field.value).font(.body)
                        // 评审修正 U2：手写徽章变体 → GradeBadge 唯一出口——
                        // D 级（识别未确认）丢失虚线+待确认胶囊视觉承诺（§1 原则 3）
                        GradeBadge(grade: field.isConfirmed ? "C" : "D")
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
        .sheet(isPresented: $showIssueSheet) {
            ReportIssueSheet(documentId: entry.id, fields: fields) { kind, fieldKey, note in
                app.reportRecognitionIssue(documentId: entry.id,
                                           meta: "kind=\(kind);field=\(fieldKey);note=\(note)")
            }
        }
        .sheet(isPresented: $showOriginal) {
            if let path = entry.originalPath, let image = UIImage(contentsOfFile: path) {
                NavigationStack {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .padding(12)
                        .navigationTitle(L10n.docViewOriginal)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.onboard_gotIt) { showOriginal = false }
                            }
                        }
                }
            }
        }
        .alert(L10n.onboardReviseTitle(reviseTarget?.displayLabel ?? ""),
               isPresented: Binding(get: { reviseTarget != nil },
                                    set: { if !$0 { reviseTarget = nil } })) {
            TextField(L10n.onboard_newValue, text: $reviseDraft)
            Button(L10n.onboard_saveEdit) {
                if let target = reviseTarget {
                    app.reviseTimelineField(entryId: entry.id, fieldId: target.id, to: reviseDraft)
                }
                reviseTarget = nil
            }
            Button(L10n.onboard_cancel, role: .cancel) { reviseTarget = nil }
        } message: {
            Text(L10n.onboardOcrRaw(reviseTarget?.rawText ?? ""))
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
                    app.auditExport(documentId: entry.id, title: L10n.docTitle(entry.title))
                })
                .accessibilityIdentifier("SP-10.document.export")
            }
            // BR-002 看原图（V3.72）：固定右上入口，原件只读展示
            if entry.originalPath != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showOriginal = true
                    } label: {
                        Label(L10n.docViewOriginal, systemImage: "doc.text.image")
                    }
                    .accessibilityIdentifier("SP-10.document.viewOriginal")
                }
            }
            // FR6.7 报告识别问题（V3.72：表单化——错误类型/字段/备注，提交落审计）
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showIssueSheet = true
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
    /// 审查修复（BR-003 代码级兜底）：只导出已确认字段——rejected/未确认
    /// 字段的识别值此前会经 ShareLink 流出设备，「仅 C 级」只写在注释里。
    private var exportText: String {
        var lines: [String] = [L10n.docTitle(entry.title), occurredDateText]
        for field in fields.filter(\.isConfirmed) {
            lines.append("\(field.displayLabel): \(field.value)")
        }
        if !entry.revisionHistory.isEmpty {
            lines.append(entry.revisionHistory.joined(separator: " → "))
        }
        return lines.joined(separator: "\n")
    }
}

/// §5.53 识别错误反馈表单（V3.72）：错误类型四分类 + 错误字段 + 备注；
/// 提交即落审计并 Toast 已记录（FR22.5 最小化：默认只附脱敏信息）。
struct ReportIssueSheet: View {
    let documentId: UUID
    let fields: [CandidateField]
    let onSubmit: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind = "fieldWrong"
    @State private var fieldKey: String?
    @State private var note = ""
    @State private var submitted = false

    private let kinds = [
        ("fieldWrong", L10n.reportIssueFieldWrong),
        ("missingField", L10n.reportIssueMissing),
        ("layout", L10n.reportIssueLayout),
        ("engine", L10n.reportIssueEngine),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.reportIssueKind) {
                    Picker("", selection: $kind) {
                        ForEach(kinds, id: \.0) { k in Text(k.1).tag(k.0) }
                    }
                    .pickerStyle(.inline)
                }
                Section(L10n.reportIssueField) {
                    Picker("", selection: $fieldKey) {
                        Text(L10n.reportIssueFieldAll).tag(String?.none)
                        ForEach(fields) { f in
                            Text(f.displayLabel).tag(String?.some(f.key))
                        }
                    }
                }
                Section(L10n.reportIssueNote) {
                    TextField(L10n.reportIssueNoteHint, text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    Text(L10n.reportIssueMinimal)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.docReportIssue)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.onboard_cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.reportIssueSubmit) {
                        onSubmit(kind, fieldKey ?? "", note)
                        submitted = true
                    }
                }
            }
            .alert(L10n.reportIssueSubmitted, isPresented: $submitted) {
                Button(L10n.onboard_gotIt, role: .cancel) { dismiss() }
            }
        }
        .presentationDetents([.medium])
    }
}
