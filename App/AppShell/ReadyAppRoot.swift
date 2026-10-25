import Foundation
import SwiftUI
import os
import Domain
import Infrastructure
import Protocols
import Perception

/// 主界面装配置根：仅当启动门发布容器后创建；`AppSession` 由 `@StateObject`
/// 保证初始化与全局副作用只执行一次，避免 SwiftUI 重复求值 body 时重复注册。
@MainActor
struct ReadyAppRoot: View {
    @State private var session: AppSession

    init(container: AppContainer, router: AppRouter,
         notificationDelegate: AppNotificationDelegate) {
        // 视图 init 可能被 SwiftUI 多次求值；会话/全局副作用只允许建一次。
        if let existing = AppSessionHolder.shared.currentSession {
            _session = State(initialValue: existing)
        } else {
            _session = State(initialValue: AppSession(
                container: container, router: router,
                notificationDelegate: notificationDelegate))
        }
    }

    var body: some View {
        WithPerceptionTracking {
            if let reason = session.container.degradedReason {
                VLUnavailableView(
                    L10n.startupDegradedTitle, systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(L10n.startupDegradedBody(reason)))
                    .accessibilityIdentifier("STARTUP.degraded")
            } else {
                mainRoot
            }
        }
    }

    /// 主界面装配（降级路径不执行——内存库上的环境装配无意义）
    @ViewBuilder
    private var mainRoot: some View {
        AppRootView(seedBundled: {
            try await session.container.guidelines.seedBundled()
            // F25 码表种子装载（V3.72）：装配层唯一调用点——幂等（app_settings
            // 记 bundle_version），失败记日志不阻断启动（码表缺 = 未解析态，FR25.1）
            try await session.container.codeIndex.loadBundledSeedsIfNeeded()
        }, backfillDocumentTypeKeys: {
            // v27 doc_type_key 首启回填（子项目 J · 原 D3-2）：装配层唯一调用点——
            // 旧行标签三语反查稳定键、未命中 custom；幂等、失败下次启动重试
            await DocumentTypeKeyBackfill.runIfNeeded(store: session.container.documents)
        })
            .environment(session.appState)
            .environment(session.reminderStore)
            // v42 用药时段 actor 非 Observable，经自定义 EnvironmentKey 注入。
            // 审查修复（2026-10-24）：此前只在 PreviewRoot 注入，生产根缺失——
            // 医疗档案 → 用药时段、提醒页 SP-15.slots.entry、提醒表单时段选择
            // 全部拿 nil 而永久转圈（预览通过掩盖了生产断链）。
            .environment(\.medicationScheduleStore, session.container.scheduleTemplates)
            .environment(session.settingsStore)
            .environment(session.avatarState)
            .environment(session.observationState)
            .environment(session.dataChangeCenter)
            .environment(session.asrInstallCenter)
            .environment(session.container.notificationCenterState)
            .environment(PendingCardCenterState(store: session.container.pendingCards,
                                                scheduler: session.container.reminderScheduler))
            .environment(session.entitlementStore)
            .environment(session.trendState)
            .environment(session.voiceNoteState)
            .environment(session.m2Hub)
            .environment(session.container.mediaSession)
            .environment(session.router)
            .environment(\.auditLog, session.container.audit)
            .environment(session.searchState)
            .environment(session.encountersState)
            .environment(HealthExamViewState(store: session.container.healthExams))
            .environment(session.timelineState)
            .environment(session.questionsState)
            .environment(session.chatHistoryState)
            .environment(session.documentsState)
            .environment(session.exportWizardState)
             .environment(session.f16DeviceState)
             .environment(session.backupState)
             .environment(session.medicalCatalogState)
             // E①（收口批）：四域参考目录端口（nil=未就绪零渲染）
             .environment(\.medicalReferenceCatalog, session.container.medicalReferenceCatalog)
             .environment(\.medicalCatalogGeneration, session.medicalCatalogState.generation)
             .environment(session.updateAdviceState)
             .environment(session.asrCheckState)
             .environment(session.llmModelInstallCenter)
             .environment(session.updateCenterState)
             // T2 模型自动补齐（2026-10-09 换型+下载化批）：幂等——仅在
             // 「已一次显式同意 ∧ 未安装 ∧ 非低电量」时发起；未同意绝不联网。
             .task { session.llmModelInstallCenter.autoInstallIfEligible() }
             // 第九轮审查修复（权益冷启动）：entitlements.owned 此前只在
             // PaywallView.task 里加载——冷启动后已购 Pro 用户首次「添加家人」
             // 会被 memberAdditionBlocked 误拦并弹付费墙（门禁读 owned 恒空）。
             // 启动即加载一次（StoreKit 只读、离线可用；失败静默，付费墙内仍可重试）。
             .task { await session.entitlementStore.load() }
    }
}

