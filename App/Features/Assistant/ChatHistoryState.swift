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
    /// 会话删除联动 Files 副本（E2 默认移除；会话行删除后账本外键置 NULL，
    /// 必须在删行前取快照，见 `delete(_:)`）。
    private let exportMirror: DocumentExportMirror?

    init(store: ChatHistoryStore, exportMirror: DocumentExportMirror? = nil) {
        self.store = store
        self.exportMirror = exportMirror
    }

    func load(patientId: UUID, query: String = "") async {
        lastQuery = query
        loadGeneration &+= 1
        let generation = loadGeneration
        do {
            let rows = try await store.conversations(patientId: patientId, query: query)
            guard generation == loadGeneration else { return }
            conversations = rows
            loadFailed = false
            loadedPatientId = patientId
        } catch {
            guard generation == loadGeneration else { return }
            // 审查席 P2：读失败不得涂成「空历史」——保留旧列表并立失败标志，
            // 空列表场景由视图显式错误态+重试承载（三值纪律）。
            loadFailed = true
            if conversations.isEmpty { conversations = [] }
        }
    }

    /// 历史读取失败标志（load 失败；成功清位）。视图据此显示错误/重试，
    /// 不得把失败画成「暂无历史」。
    private(set) var loadFailed = false

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

    /// 读取会话消息：nil = 读取失败（与「空会话」区分；三值纪律）。
    /// 保留旧 `messages` 语义的调用方请注意：新代码一律走本方法判 nil。
    func loadMessages(conversationId: UUID) async -> [ChatHistoryStore.StoredMessage]? {
        try? await store.messages(conversationId: conversationId)   // try?-ok: 语义改为可空返回值，失败由调用方显式处理
    }

    func messages(conversationId: UUID) async -> [ChatHistoryStore.StoredMessage] {
        await loadMessages(conversationId: conversationId) ?? []
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
        // 账本快照必须先于会话行删除：`document_user_export.conversation_id`
        // 外键 ON DELETE SET NULL，删行后再查 conversationID 恒为空集，
        // Files 里的导出副本将成为无主孤儿（2026-10-30 登记项）。
        let copies = await exportMirror?.copies(conversationID: id) ?? []
        do {
            try await store.delete(id)
        } catch {
            // 删除失败保留行与录音（下次重试）；不得先删录音留下无音频的幽灵会话。
            await reloadCurrentQuery()
            return
        }
        for filename in audio { ChatAudioStore.remove(filename) }
        if !copies.isEmpty { await exportMirror?.removeCopies(records: copies) }
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
