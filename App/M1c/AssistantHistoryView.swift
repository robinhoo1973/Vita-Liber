import SwiftUI
import Domain
import Infrastructure

// MARK: - FR12.10 AI 会话历史（SP-51 · ui-ux §5.27）

/// 会话历史状态仓（列表/查看/删除/清空——BR-001 成员隔离由查询强制）
@MainActor
@Observable
final class AIHistoryState {
    private(set) var conversations: [AIHistoryStore.Conversation] = []
    private let store: AIHistoryStore
    private var loadingPatientId: UUID?

    init(store: AIHistoryStore) { self.store = store }

    func load(patientId: UUID) async {
        loadingPatientId = patientId
        do {
            let rows = try await store.conversations(patientId: patientId)
            guard loadingPatientId == patientId else { return }
            conversations = rows
        } catch {
            conversations = []
        }
    }

    func messages(conversationId: UUID) async -> [AIHistoryStore.Message] {
        (try? await store.messages(conversationId: conversationId)) ?? []   // try?-ok: 读取失败=空历史降级
    }

    func delete(conversationId: UUID) async {
        do {
            try await store.deleteConversation(id: conversationId)
            if let patientId = loadingPatientId { await load(patientId: patientId) }
        } catch {
            // 同上
        }
    }

    func clearAll(patientId: UUID) async {
        do {
            try await store.clearAll(patientId: patientId)
            conversations = []
        } catch {
            // 同上
        }
    }
}

/// 会话历史：会话列表（首问摘要 + 条数 + 日期），点击回看，左滑删除，底部 [清空全部]。
/// 删除确认说明「仅删除本机会话记录，不影响原始资料」（FR12.10）。
struct AssistantHistoryView: View {
    @Environment(AppState.self) private var app
    @Environment(AIHistoryState.self) private var state
    @State private var selected: AIHistoryStore.Conversation?
    @State private var showClearConfirm = false

    var body: some View {
        List {
            if state.conversations.isEmpty {
                ContentUnavailableView(L10n.aiHistoryEmpty, systemImage: "bubble.left.and.bubble.right")
                    .accessibilityIdentifier("SP-51.history.empty")
            } else {
                ForEach(state.conversations) { conv in
                    Button {
                        selected = conv
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conv.title).font(.subheadline).lineLimit(1)
                                Text(L10n.aiHistoryCount(conv.messageCount))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(conv.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions {
                        Button(L10n.aiHistoryDelete, role: .destructive) {
                            Task { await state.delete(conversationId: conv.id) }
                        }
                    }
                    .accessibilityIdentifier("SP-51.history.row")
                }
            }
        }
        .navigationTitle(L10n.aiHistoryTitle)
        .toolbar {
            if !state.conversations.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.aiHistoryClearAll, role: .destructive) {
                        showClearConfirm = true
                    }
                    .accessibilityIdentifier("SP-51.history.clearAll")
                }
            }
        }
        .confirmationDialog(L10n.aiHistoryClearAll, isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button(L10n.aiHistoryClearAll, role: .destructive) {
                Task { await state.clearAll(patientId: app.currentPatientId) }
            }
            Button(L10n.commonCancel, role: .cancel) { }
        } message: {
            Text(L10n.aiHistoryClearNote)
        }
        .sheet(item: $selected) { conv in
            ConversationDetailView(conversation: conv)
        }
        .task(id: app.currentPatientId) { await state.load(patientId: app.currentPatientId) }
    }
}

/// 会话回看（只读；删除单条与清空在列表层）
private struct ConversationDetailView: View {
    let conversation: AIHistoryStore.Conversation
    @Environment(AIHistoryState.self) private var state
    @State private var messages: [AIHistoryStore.Message] = []

    var body: some View {
        NavigationStack {
            List(messages) { msg in
                VStack(alignment: msg.role == "user" ? .trailing : .leading, spacing: 4) {
                    Text(msg.content)
                        .font(.subheadline)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(msg.role == "user" ? Color("brand-primary", bundle: .main).opacity(0.12)
                                  : Color(.systemGray6)))
                    Text(msg.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: msg.role == "user" ? .trailing : .leading)
            }
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                messages = await state.messages(conversationId: conversation.id)
            }
        }
    }
}
