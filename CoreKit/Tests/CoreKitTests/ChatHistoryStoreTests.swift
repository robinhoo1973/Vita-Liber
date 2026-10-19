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
}
#endif
