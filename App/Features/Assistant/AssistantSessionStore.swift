import Foundation

/// AI 聊天的跨前后台/冷启动恢复身份（2026-11-03 真机：切出/锁屏后常回不到
/// 原会话）。只存「是否在聊天页 + 当前会话 ID」；消息正文仍在 ChatHistoryStore。
/// 显式关闭、SOS/语音动作换页、清空全部时清位；系统锁屏/杀进程拆掉
/// fullScreenCover 时保留，HomeView 回前台或冷启动后重开并恢复到同一会话。
enum AssistantSessionStore {
    private static let openKey = "assistant.session.open"
    private static let conversationKey = "assistant.session.conversation"

    static var isOpen: Bool {
        UserDefaults.standard.bool(forKey: openKey)
    }

    static var conversationID: UUID? {
        UserDefaults.standard.string(forKey: conversationKey).flatMap(UUID.init(uuidString:))
    }

    static func open() {
        UserDefaults.standard.set(true, forKey: openKey)
    }

    static func close() {
        UserDefaults.standard.set(false, forKey: openKey)
        UserDefaults.standard.removeObject(forKey: conversationKey)
    }

    static func saveConversation(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: conversationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: conversationKey)
        }
    }
}
