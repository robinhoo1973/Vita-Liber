import Foundation
import SwiftUI
import os
import Domain
import Infrastructure
import Protocols

/// F12 AI 助手状态仓（@Observable）：本地检索式 Provider（§5.5）+ 会话历史。
@MainActor
@Observable
final class AssistantStore {
    struct Message: Identifiable, Equatable {
        let id = UUID()
        var role: String            // user / assistant
        var text: String
        var answer: AIAnswer?
    }

    private(set) var messages: [Message] = []
    private(set) var busy = false
    private let provider: any AIProvider
    private let logger = Logger(subsystem: "com.vitaliber", category: "assistant")

    init(provider: any AIProvider) { self.provider = provider }

    func ask(_ question: String, scopePatientIds: Set<UUID>) async {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        messages.append(Message(role: "user", text: q, answer: nil))
        do {
            let answer = try await provider.answer(AIQuery(text: q),
                                                   scope: DataAccessScope(patientIds: scopePatientIds))
            messages.append(Message(role: "assistant", text: Self.render(answer), answer: answer))
        } catch {
            logger.error("AI 回答失败: \(error)")
            messages.append(Message(role: "assistant", text: "回答失败，请稍后重试。", answer: nil))
        }
    }

    /// 七段/拒识/急救卡的文本渲染（视图侧以结构化字段渲染，此处为无障碍合并文案）
    static func render(_ answer: AIAnswer) -> String {
        switch answer.body {
        case .emergencyCard:
            return "疑似紧急情况：请立即拨打 120 或前往最近的医院急诊。"
        case .refused(let r):
            return r.detail
        case .composed(let p):
            return [p.conclusion, p.excerpts.joined(separator: "\n"),
                    p.terminology.joined(separator: "\n"),
                    p.scopeNote, p.disclaimer].joined(separator: "\n\n")
        }
    }
}
