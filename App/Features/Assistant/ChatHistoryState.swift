import Foundation
import Infrastructure
import Perception

/// 聊天历史状态仓（2026-10-19 业主指令）：本机会话列表 / 读消息 / 改名 / 置顶 / 删除。
/// 只桥接 `ChatHistoryStore`，不做业务判定；聊天视图负责消息内容与卡片状态快照。
@MainActor
@Perceptible
final class ChatHistoryState {
    private(set) var conversations: [ChatHistoryStore.ConversationSummary] = []
    private(set) var loadedPatientId: UUID?

    private let store: ChatHistoryStore

    init(store: ChatHistoryStore) { self.store = store }

    func load(patientId: UUID, query: String = "") async {
        do {
            let rows = try await store.conversations(patientId: patientId, query: query)
            conversations = rows
            loadedPatientId = patientId
        } catch {
            conversations = []
        }
    }

    func createConversation(patientId: UUID, title: String) async -> UUID? {
        do { return try await store.createConversation(patientId: patientId, title: title) }
        catch { return nil }
    }

    func append(conversationId: UUID, role: String, kind: String,
                text: String, payloadJSON: String?) async {
        _ = try? await store.appendMessage(conversationId: conversationId, role: role,   // try?-ok: 历史落库尽力而为，不阻断聊天
                                           kind: kind, text: text, payloadJSON: payloadJSON)
    }

    func updateCardSnapshot(conversationId: UUID, cardId: String, state: String) async {
        try? await store.updateCardSnapshot(conversationId: conversationId, cardId: cardId, state: state)   // try?-ok: 快照更新尽力而为
    }

    /// 媒体/语音消息快照更新（状态流转、转写文本）：按客户端消息 ID 重写 payload。
    func updateMessagePayload(conversationId: UUID, clientId: UUID, payloadJSON: String) async {
        try? await store.updateMessagePayload(conversationId: conversationId, clientId: clientId, payloadJSON: payloadJSON)   // try?-ok: 历史快照更新尽力而为，不阻断聊天
    }

    func messages(conversationId: UUID) async -> [ChatHistoryStore.StoredMessage] {
        (try? await store.messages(conversationId: conversationId)) ?? []   // try?-ok: 读取失败按空历史呈现
    }

    func rename(_ id: UUID, title: String) async {
        try? await store.rename(id, title: title)   // try?-ok: 改名失败不阻断列表
        if let patientId = loadedPatientId { await load(patientId: patientId) }
    }

    func setPinned(_ id: UUID, pinned: Bool) async {
        try? await store.setPinned(id, pinned: pinned)   // try?-ok: 置顶失败不阻断列表
        if let patientId = loadedPatientId { await load(patientId: patientId) }
    }

    func delete(_ id: UUID) async {
        try? await store.delete(id)   // try?-ok: 删除失败保留行，下次重试
        if let patientId = loadedPatientId { await load(patientId: patientId) }
    }

    func count(patientId: UUID) async -> Int {
        (try? await store.count(patientId: patientId)) ?? 0   // try?-ok: 统计失败按 0
    }

    func wipeAll() async {
        try? await store.wipeAll()   // try?-ok: 擦除尽力而为
        conversations = []
    }
}
