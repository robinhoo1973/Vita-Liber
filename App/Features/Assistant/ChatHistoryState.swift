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
    /// 最近一次搜索词：改名/置顶/删除后重载必须保留搜索结果，
    /// 否则列表会突然跳回全量（用户正在搜「血压」时删除一条即失焦）。
    private(set) var lastQuery = ""
    /// 加载代次：连续输入搜索词时只接受最后一次响应，旧响应不得覆盖新列表。
    private var loadGeneration: UInt64 = 0

    private let store: ChatHistoryStore

    init(store: ChatHistoryStore) { self.store = store }

    func load(patientId: UUID, query: String = "") async {
        lastQuery = query
        loadGeneration &+= 1
        let generation = loadGeneration
        do {
            let rows = try await store.conversations(patientId: patientId, query: query)
            guard generation == loadGeneration else { return }
            conversations = rows
            loadedPatientId = patientId
        } catch {
            guard generation == loadGeneration else { return }
            conversations = []
        }
    }

    private func reloadCurrentQuery() async {
        guard let patientId = loadedPatientId else { return }
        await load(patientId: patientId, query: lastQuery)
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
        await reloadCurrentQuery()
    }

    func setPinned(_ id: UUID, pinned: Bool) async {
        try? await store.setPinned(id, pinned: pinned)   // try?-ok: 置顶失败不阻断列表
        await reloadCurrentQuery()
    }

    func delete(_ id: UUID) async {
        // 先取语音文件名再删行：数据库删除不碰文件系统，录音必须同步真删
        //（2026-10-20 隐私修复）。
        let audio = (try? await store.audioFilenames(conversationId: id)) ?? []   // try?-ok: 读取失败按无音频处理，行删除仍继续
        do {
            try await store.delete(id)
        } catch {
            // 删除失败保留行与录音（下次重试）；不得先删录音留下无音频的幽灵会话。
            await reloadCurrentQuery()
            return
        }
        for filename in audio { ChatAudioStore.remove(filename) }
        await reloadCurrentQuery()
    }

    func count(patientId: UUID) async -> Int {
        (try? await store.count(patientId: patientId)) ?? 0   // try?-ok: 统计失败按 0
    }

    func wipeAll() async {
        try? await store.wipeAll()   // try?-ok: 擦除尽力而为
        conversations = []
    }
}
