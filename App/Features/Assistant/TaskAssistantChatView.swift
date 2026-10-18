import SwiftUI
import Perception
import Domain
import Infrastructure

/// 首页 OCR/ASR 入口旁的 AI 聊天入口（2026-10-18 业主指令）。
///
/// 定位：**有据任务型助手**，不是自由医疗问答（D2 边界不变，BR-006）：
/// - 文本先过急救/高风险词表（BR-012/BR-006）；
/// - 意图分类走 FR17.19 期一确定性目录（零模型、零网络）；
/// - 缺必填槽位最多脚本化追问一次（FR17.5/FR17.8）；
/// - 一律经 FR17.13 标准确认卡 D→C 后才分发；
/// - 动作闭集与 `VoiceActionPlanner` 一致，模型/助手无权直接执行。
struct TaskAssistantChatView: View {
    @Environment(AppState.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(VoiceNoteState.self) private var voiceNotes
    @Environment(QuestionsState.self) private var questions
    @Environment(\.auditLog) private var auditLog
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var confirmSet: OcrConfirmationSet?
    @State private var pendingPlan: VoiceActionPlan?
    @State private var pendingClarification: VoiceSlotSpec?
    /// 确认卡判定结果行（FR17.19 消歧兜底：用户可在卡内改类）。
    @State private var judgedTarget: String?
    @State private var judgedConfidence: Double = 1.0
    @State private var isSaving = false
    @State private var routeMonitor = AudioRouteMonitor()

    private struct ChatMessage: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant, receipt }
        let id = UUID()
        var role: Role
        var text: String
        var isRefusal = false
        var isEmergency = false
    }

    private var suggestions: [String] {
        [L10n.assistantQuickMetric, L10n.assistantQuickReminder, L10n.assistantQuickQuestion]
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                VStack(spacing: 0) {
                    messageList
                    Divider()
                    inputBar
                }
                .navigationTitle(L10n.assistantChatTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.assistantClose) { dismiss() }
                            .accessibilityIdentifier("assistant.close")
                    }
                }
                // FR17.13-entry: task-assistant（唯一确认映射 VoiceInputTemplate.confirmationSet）
                .voiceConfirmSheet($confirmSet, route: routeMonitor.route,
                                   judgedTarget: judgedTarget,
                                   judgedConfidence: judgedConfidence,
                                   onJudgedTargetChange: { key in
                                       reclassify(to: key)
                                   }) { confirmed in
                    handleConfirmation(confirmed)
                }
                .onAppear { routeMonitor.start() }
                .onDisappear { routeMonitor.stop() }
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        emptyState
                    }
                    ForEach(messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChangeCompat(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.assistantChatEmptyTitle)
                .font(.headline)
            Text(L10n.assistantChatEmptyBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { input = suggestion }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)   // 触控目标下限（DesignSystem）
                        .accessibilityIdentifier("assistant.suggestion")
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(message.isRefusal || message.isEmergency ? Color.red : Color.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background(for: message))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private func background(for message: ChatMessage) -> Color {
        if message.isEmergency { return Color("semantic-danger", bundle: .main).opacity(0.12) }
        if message.isRefusal { return Color("semantic-warning", bundle: .main).opacity(0.12) }
        switch message.role {
        case .user: return Color("brand-primary", bundle: .main).opacity(0.14)
        case .assistant: return Color.secondary.opacity(0.10)
        case .receipt: return Color("semantic-success", bundle: .main).opacity(0.12)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(L10n.assistantChatPlaceholder, text: $input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityIdentifier("assistant.input")
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(trimmedInput.isEmpty || isSaving)
            .accessibilityLabel(L10n.assistantSend)
            .accessibilityIdentifier("assistant.send")
        }
        .padding(12)
    }

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 确定性流程

    private func send() {
        let text = trimmedInput
        guard !text.isEmpty, !isSaving else { return }
        input = ""
        append(.init(role: .user, text: text))

        // B1 定标门：未通过脚本金样定标时不得执行结构化路径（FR17.4 不变量）。
        guard FeatureFlags.voiceDeterministicEnabled else {
            append(.init(role: .assistant, text: L10n.assistantDisabled, isRefusal: true))
            return
        }

        // BR-012：急救词前置，终止解析，不生成任何动作，并进急救卡/SOS。
        if EmergencyKeywordRules.match(text) {
            handleEmergency()
            return
        }
        // BR-006：停药/调量/换药类 → 安全拒识。
        if HighRiskTopicRules.match(text) {
            append(.init(role: .assistant, text: L10n.ai_refusedHighRisk, isRefusal: true))
            return
        }

        // 脚本化补槽：只补上一个追问的槽位，不构成自由对话。
        if let spec = pendingClarification, let plan = pendingPlan {
            let filled = VoiceActionPlanner.filling(plan, key: spec.key, value: text)
            pendingClarification = nil
            presentConfirmation(for: filled)
            return
        }

        let result = VoiceIntentCatalog.classify(text, confidence: 1.0)
        let plan = VoiceActionPlanner.plan(
            intentKey: result.suggestedTarget ?? VoiceIntentKey.unknown.rawValue,
            transcript: text, drafts: result.fields,
            patientId: app.currentPatientId, source: .text)
        if plan.riskFlags.contains(.emergency) {
            handleEmergency()
            return
        }
        if plan.riskFlags.contains(.highRiskTopic) {
            append(.init(role: .assistant, text: L10n.ai_refusedHighRisk, isRefusal: true))
            return
        }
        if let spec = VoiceActionPlanner.nextClarification(for: plan) {
            pendingPlan = plan
            pendingClarification = spec
            append(.init(role: .assistant,
                         text: L10n.assistantClarify(slotLabel(spec))))
            return
        }
        presentConfirmation(for: plan, confidence: result.targetConfidence)
    }

    /// BR-012 终止路径：清空所有未完成状态，关闭会话并进 SOS（免门禁，FR1.8）。
    private func handleEmergency() {
        pendingPlan = nil
        pendingClarification = nil
        confirmSet = nil
        isSaving = false
        append(.init(role: .assistant, text: L10n.assistantEmergencyHandoff,
                     isRefusal: true, isEmergency: true))
        dismiss()
        router.navigate(to: .sosHelp)
    }

    private func presentConfirmation(for plan: VoiceActionPlan, confidence: Double = 1.0) {
        pendingPlan = plan
        judgedTarget = plan.intent.rawValue
        judgedConfidence = confidence
        confirmSet = VoiceInputTemplate.confirmationSet(drafts: plan.fieldDrafts)
    }

    /// 确认卡内改类（FR17.19「判定结果行 Menu 一键改类」）：
    /// 用同一原文重跑该意图的期一抽取，重建计划；缺槽以空字段进确认卡。
    private func reclassify(to key: String) {
        guard let plan = pendingPlan, let intent = VoiceIntentKey(rawValue: key) else { return }
        let drafts = VoiceIntentCatalog.extract(for: intent, text: plan.transcript, confidence: 1.0)
        let rebuilt = VoiceActionPlanner.plan(intentKey: key, transcript: plan.transcript,
                                              drafts: drafts, patientId: plan.patientId,
                                              source: plan.source)
        pendingClarification = nil
        // 先关旧 sheet，下一拍再呈现新 confirmSet——同一渲染帧内替换 item
        // 会让 sheet 内容与 onConfirm 捕获的旧 set 错配（改类竞态）。
        confirmSet = nil
        Task { @MainActor in
            await Task.yield()
            presentConfirmation(for: rebuilt)
        }
    }

    private func handleConfirmation(_ set: OcrConfirmationSet) {
        guard let plan = pendingPlan, !isSaving else { return }
        confirmSet = nil   // 标准确认卡一次性关闭（与 VoiceQuickLaunch 同语义）
        isSaving = true
        // 确认值重建计划：用户编辑即核对，编辑后的值以 C 级进入动作。
        let drafts = set.confirmedFields.map {
            FieldDraft(key: $0.key, value: $0.value, confidence: 1.0,
                       rawText: $0.rawText, grade: .userConfirmed)
        }
        let rebuilt = VoiceActionPlanner.plan(
            intentKey: plan.intent.rawValue, transcript: plan.transcript,
            drafts: drafts, patientId: plan.patientId, source: plan.source,
            clarificationCount: plan.clarificationCount)
        // 确认不重置 TTL：沿用原计划的时间窗，防止确认卡久留后执行旧计划。
        var ttlPreserved = rebuilt
        ttlPreserved.createdAt = plan.createdAt
        ttlPreserved.expiresAt = plan.expiresAt
        guard !ttlPreserved.riskFlags.contains(.emergency),
              !ttlPreserved.riskFlags.contains(.highRiskTopic) else {
            isSaving = false
            pendingPlan = nil
            append(.init(role: .assistant, text: L10n.ai_refusedHighRisk, isRefusal: true))
            return
        }
        // 必填仍缺：不要清计划后报通用失败，重新呈现确认卡让用户补全。
        guard ttlPreserved.missingRequiredKeys.isEmpty else {
            isSaving = false
            pendingPlan = ttlPreserved
            confirmSet = VoiceInputTemplate.confirmationSet(drafts: ttlPreserved.fieldDrafts)
            append(.init(role: .assistant, text: L10n.assistantMissingFields, isRefusal: true))
            return
        }
        let confirmationId = UUID()
        let confirmed = VoiceActionPlanner.confirming(ttlPreserved, confirmationId: confirmationId)
        let actions = VoiceActionPlanner.verifiedActions(for: confirmed,
                                                         confirmationId: confirmationId)
        guard let action = actions.first, action.patientId == app.currentPatientId else {
            isSaving = false
            pendingPlan = nil
            append(.init(role: .assistant, text: L10n.assistantSaveFailed, isRefusal: true))
            return
        }
        let audit = VoiceExecutionAudit(plan: confirmed, action: action, actor: "owner")
        recordConfirmationAudit(audit)
        pendingPlan = nil
        execute(action, plan: confirmed, audit: audit, confirmationSet: set)
    }

    private func execute(_ action: VerifiedAction, plan: VoiceActionPlan,
                         audit: VoiceExecutionAudit, confirmationSet set: OcrConfirmationSet) {
        switch action.kind {
        case .recordMetric:
            route(.metricQuickEntry, plan: plan, action: action, set: set)
        case .createReminder:
            route(.voiceReminderDraft, plan: plan, action: action, set: set)
        case .appendProfile:
            route(.voiceGuideProfile, plan: plan, action: action, set: set)
        case .recordObservation:
            route(.observationCreate, plan: plan, action: action, set: set)
        case .createAppointment:
            route(.appointmentForm(nil), plan: plan, action: action, set: set)
        case .createQuestion:
            let body = action.slotValues["question"] ?? action.rawTranscript
            Task {
                let ok = await questions.add(patientId: action.patientId, body: body, audit: audit)
                await MainActor.run { finishDirectSave(ok: ok, text: L10n.assistantSavedQuestion) }
            }
        case .appendNote:
            let body = action.slotValues["note"] ?? action.rawTranscript
            Task {
                let ok = await voiceNotes.create(patientId: action.patientId, body: body,
                                                 tags: nil, audit: audit)
                await MainActor.run { finishDirectSave(ok: ok, text: L10n.assistantSavedNote) }
            }
        case .appendMedDraft:
            // 期二接线：只允许 raw-text 草稿，不写计划/库存/提醒。
            isSaving = false
            append(.init(role: .assistant, text: L10n.assistantMedDraftDeferred, isRefusal: true))
        }
    }

    private func route(_ target: AppRoute, plan: VoiceActionPlan,
                       action: VerifiedAction, set: OcrConfirmationSet) {
        // 一次性投递：已有未消费草稿时拒绝覆盖（防止上一个动作被静默顶掉）。
        guard router.pendingVoiceIntent == nil else {
            isSaving = false
            append(.init(role: .assistant, text: L10n.assistantSaveFailed, isRefusal: true))
            return
        }
        router.pendingVoiceIntent = set.pendingIntent(
            plan.intent.rawValue, patientId: plan.patientId,
            sourcePlanId: plan.planId, confirmationId: action.confirmationId,
            idempotencyKey: action.idempotencyKey, actionKind: action.kind.rawValue)
        isSaving = false
        router.navigate(to: target)
        dismiss()
    }

    /// 确认事件审计（与业务写分事务，只记录交接；直存动作另有同事务 `voice.execute`）。
    /// 审计失败不阻断用户保存（best-effort；错误留待 L2 观测）。
    private func recordConfirmationAudit(_ audit: VoiceExecutionAudit) {
        guard let auditLog else { return }
        let meta = audit.metaJSON
        let planId = audit.planId
        let actor = audit.actorLocal
        Task {
            do {
                try await auditLog.record(action: AuditLogWriter.Action.voiceConfirm,
                                          entityType: "voice_plan",
                                          entityId: planId.uuidString,
                                          actorLocal: actor, meta: meta)
            } catch {
                // 审计失败不阻断确认/保存；动作自身的 voice.execute 仍按同事务写。
            }
        }
    }

    private func finishDirectSave(ok: Bool, text: String) {
        isSaving = false
        append(.init(role: .receipt, text: ok ? text : L10n.assistantSaveFailed,
                     isRefusal: !ok))
    }

    private func slotLabel(_ spec: VoiceSlotSpec) -> String {
        L10n.voiceSlotLabel(spec.displayLabelKey)
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
    }
}
