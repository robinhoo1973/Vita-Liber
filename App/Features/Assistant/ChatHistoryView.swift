import SwiftUI
import Infrastructure
import Perception

/// 对话历史（2026-10-19 业主指令）：本机会话列表，按今天/昨天/更早分组；
/// 支持搜索、重命名、置顶、删除（真删）。点行恢复到聊天，右上角新建会话。
struct ChatHistoryView: View {
    @Environment(ChatHistoryState.self) private var history
    let patientId: UUID
    let onOpen: (ChatHistoryStore.ConversationSummary) -> Void
    let onNew: () -> Void
    let onClose: () -> Void
    /// 删除完成后通知父页（删除的正是当前会话时必须重置，否则后续消息
    /// 写入已删除会话的外键失败；2026-10-20）。
    var onDelete: (UUID) -> Void = { _ in }
    /// 改名完成后通知父页：当前会话标题须回流，否则随后导入的「文件」App
    /// 会话目录仍用旧名（2026-10-30 复审）。
    var onRename: (UUID, String) -> Void = { _, _ in }

    @State private var query = ""
    @State private var renameTarget: ChatHistoryStore.ConversationSummary?
    @State private var renameText = ""
    @State private var deleteTarget: ChatHistoryStore.ConversationSummary?

    private var sections: [(title: String, rows: [ChatHistoryStore.ConversationSummary])] {
        let calendar = Calendar.current
        let today = history.conversations.filter { calendar.isDateInToday($0.updatedAt) }
        let yesterday = history.conversations.filter { calendar.isDateInYesterday($0.updatedAt) }
        let earlier = history.conversations.filter {
            !calendar.isDateInToday($0.updatedAt) && !calendar.isDateInYesterday($0.updatedAt)
        }
        return [(L10n.assistantHistoryToday, today),
                (L10n.assistantHistoryYesterday, yesterday),
                (L10n.assistantHistoryEarlier, earlier)].filter { !$0.1.isEmpty }
    }

    @ViewBuilder
    private var historyContent: some View {
        if history.conversations.isEmpty {
            if history.loadFailed {
                historyFailedEmpty
            } else {
                VLUnavailableView(L10n.assistantHistoryEmpty, systemImage: "clock.arrow.circlepath")
            }
        } else {
            historyList
        }
    }

    private var historyFailedEmpty: some View {
        // （title, systemImage:）重载没有 actions 槽——重试按钮须走 label+actions 重载
        // （同 RouteDestinationView 文档失败态；CI 40893094838 编译错「trailing closure
        // passed to parameter of type 'Text'」的根因）。
        VLUnavailableView {
            Label(L10n.assistantHistoryLoadFailed, systemImage: "exclamationmark.triangle")
        } actions: { retryButton }
    }

    private var retryButton: some View {
        Button(L10n.retry) {
            Task { await history.load(patientId: patientId, query: query) }
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("assistant.history.retry")
    }

    private var historyList: some View {
        List {
            if history.loadFailed {
                Button {
                    Task { await history.load(patientId: patientId, query: query) }
                } label: {
                    Label(L10n.assistantHistoryLoadFailed, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                }
                .accessibilityIdentifier("assistant.history.retry")
            }
            ForEach(sections, id: \.title) { section in
                Section {
                    ForEach(section.rows) { row in
                        rowView(row)
                    }
                } header: {
                    Text(section.title)
                }
            }
        }
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                // 审查席 P2（三值纪律）：读失败 ≠ 空历史。拆分为独立 builder——
                // 单表达式内嵌 VLUnavailableView 分派曾触发型检超时（CI 40888035668）。
                Group {
                    historyContent
                }
                .navigationTitle(L10n.assistantHistoryTitle)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: Text(L10n.assistantHistorySearch))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.assistantClose) { onClose() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            onNew()
                        } label: {
                            Label(L10n.assistantHistoryNew, systemImage: "plus")
                        }
                        .accessibilityIdentifier("assistant.history.new")
                    }
                }
                .task(id: query) {
                    await history.load(patientId: patientId, query: query)
                }
                .alert(L10n.assistantHistoryRename, isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } })) {
                    TextField(L10n.assistantHistoryRenamePrompt, text: $renameText)
                    Button(L10n.commonCancel, role: .cancel) { renameTarget = nil }
                    Button(L10n.commonConfirm) {
                        if let target = renameTarget {
                            let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                            // 空标题不落库：否则历史行变无名，导出目录也会失去会话名。
                            if !title.isEmpty {
                                onRename(target.id, title)
                                Task { await history.rename(target.id, title: title) }
                            }
                        }
                        renameTarget = nil
                    }
                }
                .confirmationDialog(L10n.assistantHistoryDeleteBody,
                                    isPresented: Binding(
                                        get: { deleteTarget != nil },
                                        set: { if !$0 { deleteTarget = nil } }),
                                    titleVisibility: .visible) {
                    Button(L10n.assistantHistoryDelete, role: .destructive) {
                        if let target = deleteTarget {
                            onDelete(target.id)
                            Task { await history.delete(target.id) }
                        }
                        deleteTarget = nil
                    }
                    Button(L10n.commonCancel, role: .cancel) { deleteTarget = nil }
                }
            }
        }
    }

    private func rowView(_ row: ChatHistoryStore.ConversationSummary) -> some View {
        Button {
            onOpen(row)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if row.pinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(Color("brand-primary", bundle: .main))
                                .accessibilityLabel(L10n.assistantHistoryPin)
                        }
                        // 业主 2026-10-29：标题给两行，信息量优先；第二行不再重复
                        // 预览标题，改显示消息数量（日期/星期在右侧时间列）。
                        Text(row.title)
                            .font(.body)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(L10n.assistantHistoryMessages(row.messageCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.updatedAt.formatted(.dateTime.month(.twoDigits)
                        .day(.twoDigits).weekday(.abbreviated)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(row.updatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                // 日期列保持完整（中文「周四」不折行），标题两行可让位。
                .layoutPriority(1)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameTarget = row
                renameText = row.title
            } label: { Label(L10n.assistantHistoryRename, systemImage: "pencil") }
            Button {
                Task { await history.setPinned(row.id, pinned: !row.pinned) }
            } label: {
                Label(row.pinned ? L10n.assistantHistoryUnpin : L10n.assistantHistoryPin,
                      systemImage: row.pinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                deleteTarget = row
            } label: { Label(L10n.assistantHistoryDelete, systemImage: "trash") }
        }
        // 业主 2026-10-29：删除与置顶不再挤在同一侧。置顶=前缘非破坏操作
        //（可全滑），删除=后缘破坏操作（禁止全滑，避免误删）。重命名留在
        // 长按菜单——滑动只保留高频两项，减少图标噪声。
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await history.setPinned(row.id, pinned: !row.pinned) }
            } label: {
                Label(row.pinned ? L10n.assistantHistoryUnpin : L10n.assistantHistoryPin,
                      systemImage: row.pinned ? "pin.slash" : "pin")
            }
            .tint(Color("brand-primary", bundle: .main))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteTarget = row
            } label: { Label(L10n.assistantHistoryDelete, systemImage: "trash") }
        }
    }
}
