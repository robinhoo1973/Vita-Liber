import Testing
@testable import Domain

/// 待核对卡生命周期规则（业主裁决 A，2026-10-30）：到期归档可补办，
/// 三处投影/恢复页/聊天详情共同消费同一规则（此前各自白名单 → D 级死胡同）。
@Suite("待核对卡生命周期规则")
struct PendingCardLifecycleRulesTests {
    @Test("活跃三态可直接续办；归档态按 resolvedBy 走补办")
    func resumeMatrix() {
        #expect(PendingCardLifecycleRules.canResume(status: "pending", resolvedBy: nil))
        #expect(PendingCardLifecycleRules.canResume(status: "in_progress", resolvedBy: nil))
        #expect(PendingCardLifecycleRules.canResume(status: "expired", resolvedBy: nil))
        #expect(PendingCardLifecycleRules.canResume(status: "archived", resolvedBy: "expired"))
        #expect(PendingCardLifecycleRules.canResume(status: "archived", resolvedBy: "user"))
        #expect(PendingCardLifecycleRules.canResume(status: "archived", resolvedBy: nil))
        #expect(!PendingCardLifecycleRules.canResume(status: "resolved", resolvedBy: "user"))
        #expect(!PendingCardLifecycleRules.canResume(status: "archived", resolvedBy: "llm"))
    }

    @Test("可见性：归档进入详情投影（补办入口），resolved 仍不可见")
    func visibility() {
        #expect(PendingCardLifecycleRules.isVisible(status: "pending"))
        #expect(PendingCardLifecycleRules.isVisible(status: "expired"))
        #expect(PendingCardLifecycleRules.isVisible(status: "archived"))
        #expect(!PendingCardLifecycleRules.isVisible(status: "resolved"))
    }

    @Test("canRestore 只对归档态为真（活跃/完结均为假）")
    func restoreOnlyForArchived() {
        #expect(PendingCardLifecycleRules.canRestore(status: "archived", resolvedBy: "expired"))
        #expect(!PendingCardLifecycleRules.canRestore(status: "pending", resolvedBy: nil))
        #expect(!PendingCardLifecycleRules.canRestore(status: "expired", resolvedBy: nil))
        #expect(!PendingCardLifecycleRules.canRestore(status: "resolved", resolvedBy: "user"))
    }
}
