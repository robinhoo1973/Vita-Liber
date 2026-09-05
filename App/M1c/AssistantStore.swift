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
    /// FR12.10 会话历史落库（可选注入——预览/测试可空）
    private let history: AIHistoryStore?
    /// FR12.8 反馈四键审计出口（有用/无用/引用错误/疑似危险，本地留存）
    private let feedback: ((String) -> Void)?
    /// 当前会话（首问即开新会话；BR-001 按成员隔离）
    private(set) var currentConversationId: UUID?
    private var conversationPatientId: UUID?
    private let logger = Logger(subsystem: "com.vitaliber", category: "assistant")

    init(provider: any AIProvider, history: AIHistoryStore? = nil,
         feedback: ((String) -> Void)? = nil, quotaUseHook: (() -> Void)? = nil) {
        self.provider = provider
        self.history = history
        self.feedback = feedback
        self.quotaUseHook = quotaUseHook
    }

    func ask(_ question: String, scopePatientIds: Set<UUID>) async {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        messages.append(Message(role: "user", text: q, answer: nil))
        // FR12.10：首问即开新会话（标题=首问摘要，截断 30 字）。
        // 审查修复（BR-001）：成员切换必须开新会话——原实现只判
        // currentConversationId == nil，A 成员开立的会话在切到 B 成员后
        // 继续追加 B 的问题与回答，B 的健康信息混进 A 的会话历史。
        if let history {
            let patientId = scopePatientIds.first
            if currentConversationId == nil || (patientId != nil && patientId != conversationPatientId) {
                if let patientId {
                    do {
                        let title = String(q.prefix(30))
                        // 审查修复：去掉 currentConversationId!——改为局部绑定，
                        // 赋值与使用之间永不出现隐式解包 trap 的窗口
                        let conv = try await history.startConversation(patientId: patientId, title: title)
                        currentConversationId = conv
                        conversationPatientId = patientId
                        try await history.appendMessage(conversationId: conv, role: "user",
                                                        content: q, citationIds: nil)
                    } catch {
                        logger.error("会话开立失败: \(error)")
                    }
                }
            } else if let conv = currentConversationId {
                do {
                    try await history.appendMessage(conversationId: conv, role: "user",
                                                    content: q, citationIds: nil)
                } catch {
                    logger.error("会话追加失败: \(error)")
                }
            }
        }
        do {
            // BR-012/BR-006 纵深防御由 Domain 的 SafeAIProvider 装饰器统一保证
            // （装配于 AppContainer）——Store 不做业务判断，只负责会话与渲染。
            let answer = try await provider.answer(AIQuery(text: q),
                                                   scope: DataAccessScope(patientIds: scopePatientIds))
            messages.append(Message(role: "assistant", text: Self.render(answer), answer: answer))
            recordQuotaUse()   // comercial §2.3：AI 用量真实计数（免费档 20 次/月）
            if let history, let conv = currentConversationId {
                var citationIds: String?
                if case .composed(let parts) = answer.body {
                    citationIds = parts.citations.map(\.refID.uuidString).joined(separator: ",")
                }
                try? await history.appendMessage(conversationId: conv, role: "assistant",   // try?-ok: 历史追加失败不影响回答呈现（主链路已渲染）
                                                 content: Self.render(answer), citationIds: citationIds)
            }
        } catch {
            logger.error("AI 回答失败: \(error)")
            messages.append(Message(role: "assistant", text: L10n.ai_failedRetry, answer: nil))
        }
    }

    /// FR12.8 反馈四键（本地留存；P1 上报）
    func recordFeedback(kind: String) {
        feedback?(kind)
    }

    /// comercial §2.3 免费额度计数：每次成功回答计一次用量（注入闭包，
    /// 装配层接 AppEntitlementStore.recordAIUse——用量必须真实计数）。
    /// 基础问答本身永久免费（§2.1）：额度只做商业化语义的诚实呈现，
    /// 不在基础问答上设任何门限（L0 [4/9] 红线模块断言同款纪律）。
    private let quotaUseHook: (() -> Void)?
    func recordQuotaUse() { quotaUseHook?() }

    /// 新会话（FR12.10：清当前上下文开新会话）
    func startNewConversation(patientId: UUID) {
        currentConversationId = nil
        conversationPatientId = patientId
        messages = []
    }

    /// 七段/拒识/急救卡的文本渲染（视图侧以结构化字段渲染，此处为无障碍合并文案
    /// 与持久化历史文本的单一出口——V3.70 与视图同走结构化字段，历史不再丢内容）
    static func render(_ answer: AIAnswer) -> String {
        switch answer.body {
        case .emergencyCard:
            return L10n.ai_emergencyCardText
        case .refused(let r):
            return refusalDetail(r.reason)
        case .composed(let p):
            let terms = p.terminologyPairs
                .map { L10n.aiTerm($0.term, $0.explanation) }
                .joined(separator: "\n")
            return [L10n.aiConclusion(p.citationCount),
                    p.excerpts.joined(separator: "\n"),
                    terms,
                    L10n.aiScopeNote(p.citationCount),
                    L10n.aiDisclaimerFixed].joined(separator: "\n\n")
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
