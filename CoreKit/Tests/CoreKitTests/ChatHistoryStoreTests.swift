// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— 须经 macOS CI 验证
#if os(iOS) || os(macOS)
import Foundation
import Testing
import GRDB
@testable import Domain
@testable import Infrastructure

// binds: SU-M2-CHATHISTORY — 聊天历史本机持久化（2026-10-19/20）
@Suite("SU-M2-CHATHISTORY · 会话/消息持久化与媒体快照更新")
struct ChatHistoryStoreTests {
    private func store(_ patient: UUID) async throws -> (ChatHistoryStore, DatabaseQueue) {
        let dbQueue = try DatabaseQueue(configuration: GRDBStore.configuration())
        try await dbQueue.write { db in
            try db.execute(sql: SchemaV2.ddl)
            try db.execute(sql: """
                INSERT INTO patient_profile
                  (id, display_name, relation, created_at, updated_at)
                VALUES (?, '王女士', 'self', ?, ?)
                """, arguments: [patient.uuidString, Date().timeIntervalSince1970,
                                 Date().timeIntervalSince1970])
        }
        return (ChatHistoryStore(writer: dbQueue), dbQueue)
    }

    /// 媒体消息按 clientId 重写快照：processing → ready 后历史读回 ready。
    @Test("媒体 payload 按 clientId 更新且历史读回新状态")
    func updateMediaPayloadByClientId() async throws {
        let patient = UUID()
        let (history, _) = try await store(patient)
        let conversation = try await history.createConversation(patientId: patient, title: "对话")
        let client = UUID()
        let processing = #"{"clientId":"\#(client.uuidString)","role":"user","text":"","isRefusal":false,"isEmergency":false,"media":{"kind":"image","filename":"照片","status":"processing"}}"#
        _ = try await history.appendMessage(conversationId: conversation, role: "user",
                                            kind: "media", text: "", payloadJSON: processing)
        let ready = processing.replacingOccurrences(of: "\"processing\"", with: "\"ready\"")
        try await history.updateMessagePayload(conversationId: conversation,
                                               clientId: client, payloadJSON: ready)
        let stored = try await history.messages(conversationId: conversation)
        #expect(stored.count == 1)
        #expect(stored.first?.payloadJSON?.contains("\"status\":\"ready\"") == true)
        #expect(stored.first?.payloadJSON?.contains(client.uuidString) == true)
    }


    /// 语音文件名可枚举（删除会话时清理音频）且转写文本参与搜索（2026-10-20）。
    @Test("语音文件名枚举 + 转写文本可搜索")
    func audioFilenamesAndTranscriptSearch() async throws {
        let patient = UUID()
        let (history, _) = try await store(patient)
        let conversation = try await history.createConversation(patientId: patient, title: "语音")
        let payload = #"{"clientId":"\#(UUID().uuidString)","role":"user","text":"","isRefusal":false,"isEmergency":false,"media":{"kind":"voice","filename":"语音消息","status":"ready","audioFilename":"voice-a.caf","transcript":"血压高压一百二"}}"#
        _ = try await history.appendMessage(conversationId: conversation, role: "user",
                                            kind: "media", text: "", payloadJSON: payload)
        let files = try await history.audioFilenames(conversationId: conversation)
        #expect(files == ["voice-a.caf"])
        let hits = try await history.conversations(patientId: patient, query: "高压")
        #expect(hits.map(\.id) == [conversation])
    }

    /// 语音消息与转写文本随会话读回，删除会话级联真删消息。
    @Test("语音消息转写文本持久化且会话删除级联")
    func voiceTranscriptPersistsAndDeleteCascades() async throws {
        let patient = UUID()
        let (history, _) = try await store(patient)
        let conversation = try await history.createConversation(patientId: patient, title: "语音")
        let payload = #"{"clientId":"\#(UUID().uuidString)","role":"user","text":"","isRefusal":false,"isEmergency":false,"media":{"kind":"voice","filename":"语音消息","status":"ready","audioFilename":"voice-a.caf","transcript":"血压高压120"}}"#
        _ = try await history.appendMessage(conversationId: conversation, role: "user",
                                            kind: "media", text: "", payloadJSON: payload)
        let stored = try await history.messages(conversationId: conversation)
        #expect(stored.first?.payloadJSON?.contains("血压高压120") == true)
        try await history.delete(conversation)
        let after = try await history.messages(conversationId: conversation)
        #expect(after.isEmpty)
    }

    /// 卡片消息不再属于聊天流（2026-10-29 业主）：计数/预览只算非 card；
    /// 仅含旧卡片的会话不得以空会话进入历史列表。
    /// 单条损坏 payload 不得让整张历史列表查询抛错（否则 UI 把全部会话涂成空）。
    @Test("损坏 payload 不阻断历史列表与搜索")
    func malformedPayloadDoesNotBreakConversationList() async throws {
        let patient = UUID()
        let (history, _) = try await store(patient)
        let conversation = try await history.createConversation(patientId: patient, title: "损坏快照")
        _ = try await history.appendMessage(conversationId: conversation, role: "user",
                                            kind: "text", text: "", payloadJSON: "{not json")
        let rows = try await history.conversations(patientId: patient)
        #expect(rows.map(\.id) == [conversation])
        #expect(rows.first?.messageCount == 1)
        #expect(rows.first?.preview == "")
        let search = try await history.conversations(patientId: patient, query: "任意词")
        #expect(search.isEmpty)
    }

    /// 审查席 P2：损坏 payload 家族须全读面加固——audioFilenames 抛错会让删除
    /// 前置读被吞成 []，语音文件成孤儿（BR-007 残留）；updateCardSnapshot 抛错
    /// 会让快照静默失败。
    @Test("损坏 payload 不阻断 audioFilenames 与 updateCardSnapshot")
    func malformedPayloadDoesNotBreakAudioOrSnapshotUpdates() async throws {
        let patient = UUID()
        let (history, dbQueue) = try await store(patient)
        let conversation = try await history.createConversation(patientId: patient, title: "损坏")
        let badId = UUID()
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO chat_message
                  (id, conversation_id, role, kind, text, payload_json, created_at, seq)
                VALUES (?, ?, 'user', 'media', '', '{not json', ?, 1)
                """, arguments: [badId.uuidString, conversation.uuidString, Date().timeIntervalSince1970])
        }
        let files = try await history.audioFilenames(conversationId: conversation)
        #expect(files.isEmpty)
        try await history.updateCardSnapshot(conversationId: conversation, cardId: "x", state: "done")
        try await history.updateMessagePayload(conversationId: conversation, clientId: UUID(),
                                               payloadJSON: #"{"clientId":"y"}"#)
    }

    @Test("卡片消息不计入历史消息数与预览，卡片专用会话不显示")
    func cardMessagesExcludedFromHistorySummary() async throws {
        let patient = UUID()
        let (history, _) = try await store(patient)
        let conversation = try await history.createConversation(patientId: patient, title: "对话")
        _ = try await history.appendMessage(conversationId: conversation, role: "user",
                                            kind: "text", text: "你好", payloadJSON: nil)
        let cardPayload = #"{"clientId":"\#(UUID().uuidString)","role":"assistant","text":"","isRefusal":false,"isEmergency":false,"card":{"id":"\#(UUID().uuidString)","kind":"entity","fieldCount":3,"sessionID":"\#(UUID().uuidString)","snapshotState":"done","title":"检验报告"}}"#
        _ = try await history.appendMessage(conversationId: conversation, role: "assistant",
                                            kind: "card", text: "", payloadJSON: cardPayload)
        let rows = try await history.conversations(patientId: patient)
        #expect(rows.count == 1)
        #expect(rows.first?.messageCount == 1)
        #expect(rows.first?.preview == "你好")

        let cardOnly = try await history.createConversation(patientId: patient, title: "旧卡片")
        _ = try await history.appendMessage(conversationId: cardOnly, role: "assistant",
                                            kind: "card", text: "", payloadJSON: cardPayload)
        let after = try await history.conversations(patientId: patient)
        #expect(after.map(\.id) == [conversation])
        let search = try await history.conversations(patientId: patient, query: "检验报告")
        #expect(search.isEmpty)
    }
}
#endif
