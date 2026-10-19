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

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Group {
                    if history.conversations.isEmpty {
                        VLUnavailableView(L10n.assistantHistoryEmpty, systemImage: "clock.arrow.circlepath")
                    } else {
                        List {
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
                            Task { await history.rename(target.id, title: renameText) }
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
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if row.pinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(Color("brand-primary", bundle: .main))
                        }
                        Text(row.title)
                            .font(.body)
                            .lineLimit(1)
                    }
                    Text(row.preview.isEmpty ? L10n.assistantHistoryNoPreview : row.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(row.updatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(L10n.assistantHistoryMessages(row.messageCount))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
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
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteTarget = row
            } label: { Label(L10n.assistantHistoryDelete, systemImage: "trash") }
            Button {
                Task { await history.setPinned(row.id, pinned: !row.pinned) }
            } label: {
                Label(row.pinned ? L10n.assistantHistoryUnpin : L10n.assistantHistoryPin,
                      systemImage: row.pinned ? "pin.slash" : "pin")
            }
            .tint(Color("brand-primary", bundle: .main))
        }
    }
}
