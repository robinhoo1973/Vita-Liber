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
            // BR-012/BR-006 纵深防御由 Domain 的 SafeAIProvider 装饰器统一保证
            // （装配于 AppContainer）——Store 不做业务判断，只负责会话与渲染。
            let answer = try await provider.answer(AIQuery(text: q),
                                                   scope: DataAccessScope(patientIds: scopePatientIds))
            messages.append(Message(role: "assistant", text: Self.render(answer), answer: answer))
        } catch {
            logger.error("AI 回答失败: \(error)")
            messages.append(Message(role: "assistant", text: L10n.ai_failedRetry, answer: nil))
        }
    }

    /// 七段/拒识/急救卡的文本渲染（视图侧以结构化字段渲染，此处为无障碍合并文案）
    static func render(_ answer: AIAnswer) -> String {
        switch answer.body {
        case .emergencyCard:
            return L10n.ai_emergencyCardText
        case .refused(let r):
            return refusalDetail(r.reason)
        case .composed(let p):
            return [p.conclusion, p.excerpts.joined(separator: "\n"),
                    p.terminology.joined(separator: "\n"),
                    p.scopeNote, p.disclaimer].joined(separator: "\n\n")
        }
    }

    /// 拒识文案的**唯一呈现出口**：按类型化 reason 取三语文案。
    ///
    /// 为什么不直接用 `Refusal.detail`：Domain 里的 detail 是简体硬编码（纯 Swift 层
    /// 拿不到 .strings），上屏就等于 zh-Hant/en 用户看到简体，且同一情形会存在
    /// 「Domain 一套 + L10n 一套」两种说法。detail 因此降级为诊断/测试用默认值，
    /// 呈现层一律走这里——新增 Reason 时编译器会在此强制补文案（switch 穷尽）。
    static func refusalDetail(_ reason: AIAnswer.Refusal.Reason) -> String {
        switch reason {
        case .insufficientData: return L10n.ai_refusedNoEvidence
        case .highRiskTopic:    return L10n.ai_refusedHighRisk
        }
    }
}
