import SwiftUI
import Domain
import Protocols

/// FR17.10 语音提醒设定 + FR17.11 语音引导式档案注册/完善（SP-58）。
/// 两者的确认一律走 `VoiceConfirmSheet`（FR17.13），本文件不含任何自建确认 UI。

// MARK: - FR17.10 语音提醒设定

/// 一句话说出提醒 → 文法抽取时间/重复 → 统一模板确认 → 入 Reminder 实体。
@MainActor
struct VoiceReminderDraftView: View {
    @Environment(AppState.self) private var app
    @Environment(AppRouter.self) private var router
    /// 调度结果必须回传（审查修复：此前 Void——调度失败仍弹「已保存」，
    /// 用户以为提醒已设置实则永不触发）
    let onCommit: (_ title: String, _ fireAt: Date, _ repeatRule: String?) async -> Bool

    @State private var transcript = ""
    @State private var confirmSet: OcrConfirmationSet?
    @State private var routeMonitor = AudioRouteMonitor()
    @State private var unresolved: String?
    @State private var savedAlert = false
    @State private var dictationBusy = false
    @State private var dictationScope = UUID()
    @State private var dictationConfidence: Double = 1

    var body: some View {
        let scope = dictationScope
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.voiceguide_reminderTitle).font(.headline)
            Text(L10n.voiceguide_reminderExample)
                .font(.caption).foregroundStyle(.secondary)
            // TestFlight 实测修复：录音听写按钮（与手输共填同一文本，on-device 识别）
            VoiceDictationButton(onTranscript: { text, confidence in
                guard dictationScope == scope, !text.isEmpty else { return }
                dictationConfidence = min(dictationConfidence, confidence)
                transcript = transcript.isEmpty ? text : transcript + "\n" + text
            }, isBusy: Binding(get: { dictationBusy }, set: { busy in
                if dictationScope == scope { dictationBusy = busy }
            }))
            .id(scope)
            TextField(L10n.voiceguide_transcript, text: $transcript, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .accessibilityIdentifier("FR17.10.transcript")

            if let unresolved {
                Label(unresolved, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color("grade-d", bundle: .main))
                    .accessibilityIdentifier("FR17.10.unresolved")
            }

            Button {
                buildDraft()
            } label: {
                Label(L10n.voiceguide_buildDraft, systemImage: "bell").frame(minHeight: 44)
            }
            .disabled(dictationBusy || transcript.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("FR17.10.build")
            Spacer()
        }
        .padding(16)
        .voiceConfirmSheet($confirmSet, route: routeMonitor.route) { confirmed in
            confirmSet = nil
            Task { await commit(confirmed) }
        }
        .onAppear {
            routeMonitor.start()
            // FR17.9 §5.54：语音面板确认后的提醒草稿一次性预填——
            // 确认字段回填转写输入，本页二次核对后走本页自己的确认
            if let draft = router.pendingVoiceIntent {
                router.pendingVoiceIntent = nil
                if transcript.isEmpty {
                    if let content = draft.keyedValues["content"], !content.isEmpty {
                        transcript = content
                    } else {
                        // 提醒文法槽位无 content 键（hour/date/time/repeat）——
                        // 此前恒查 content 落空、已确认时间槽位静默丢弃；重组
                        // 「日期 + N点」进正文区（Domain 纯函数，视图零字面量），
                        // 用户二次核对后按本页流程重抽
                        let joined = VoiceInputTemplate.reminderTranscript(from: draft.fields)
                        if !joined.isEmpty { transcript = joined }
                    }
                }
            }
        }
        .onDisappear { routeMonitor.stop() }
        .alert(L10n.voiceguide_saved, isPresented: $savedAlert) {
            Button(L10n.onboard_gotIt, role: .cancel) { }
        }
    }

    private func buildDraft() {
        guard !dictationBusy else { return }
        unresolved = nil
        var drafts = VoiceStructuringEngine.extractReminder(transcript, rules: VoiceGrammarDefaults.reminderRules)
        for index in drafts.indices {
            drafts[index].confidence = min(drafts[index].confidence, dictationConfidence)
        }
        // 提醒内容 = 原文（确认卡上可编辑，业界确认卡惯例：内容恒可改）——
        // content 恒被追加，drafts 不可能为空，时间可解析性由 resolveDate 统一判
        drafts.append(FieldDraft(key: "content", value: transcript, confidence: min(0.9, dictationConfidence)))
        // 模糊时间必须落成具体日期后才允许确认（FR17.10：草稿逐字段可改）
        guard VoiceReminderRules.resolveDate(from: drafts, now: Date()) != nil else {
            unresolved = L10n.voiceReminderTimeUnclear
            return
        }
        // FR17.13-entry: 提醒草稿 —— 走统一模板，不自建确认逻辑
        confirmSet = VoiceInputTemplate.confirmationSet(drafts: drafts)
    }

    private func commit(_ set: OcrConfirmationSet) async {
        let drafts = set.confirmedFields.map {
            FieldDraft(key: $0.key, value: $0.value, confidence: $0.confidence)
        }
        // resolveDate 自批四起对非法 hour 返回 nil（绝不猜 00:00）——确认卡被改成
        // 非法时刻时不得静默丢弃，退回澄清提示（FR10.2 同语义）
        guard let fireAt = VoiceReminderRules.resolveDate(from: drafts, now: Date()) else {
            unresolved = L10n.voiceReminderTimeUnclear
            return
        }
        let title = drafts.first { $0.key == "content" }?.value ?? transcript
        let rule = drafts.first { $0.key == "repeat" }?.value
        dictationScope = UUID()
        dictationBusy = false
        dictationConfidence = 1
        transcript = ""
        // 审查修复：调度失败必须可见（此前后台吞错 + 无条件弹「已保存」，
        // 用户以为提醒已设置——通知权限被拒/调度抛错时提醒永不触发）
        let ok = await onCommit(title, fireAt, rule)
        if ok {
            savedAlert = true   // TestFlight 实测修复：保存后必须有可见反馈（引导用户知道提醒已设置）
        } else {
            unresolved = L10n.voiceReminderSaveFailed
        }
    }
}

// MARK: - FR17.11 语音引导式档案（SP-58）

/// 「系统问一步、用户答一步」的档案访谈。每步答案 → 统一模板确认 → 写入档案字段。
/// 对既有用药计划的剂量/频次/停用修改一律弹拒绝卡（BR-003/006）。
@MainActor
struct VoiceGuidedProfileView: View {
    @Environment(AppState.self) private var app
    @Environment(AppRouter.self) private var router
    /// 写入成败必须回传（审查修复：此前 Void + 调用方丢弃——落库失败时
    /// 答案静默丢失而访谈照常前进，用户以为已保存）
    let onCommitField: (_ key: String, _ value: String) async -> Bool

    /// 访谈步骤（FR17.11 + FR3.1 紧急联系人基础字段随本条提前至 P0.5）
    private let steps: [(key: String, prompt: String)] = [
        ("allergy", L10n.voiceguide_promptAllergy),
        ("pastHistory", L10n.voiceguide_promptHistory),
        ("currentMeds", L10n.voiceguide_promptMeds),
        ("emergencyContact", L10n.voiceguide_promptContact),
    ]

    /// 访谈三阶段（审查修复：此前 consentGiven/micChecked 两布尔构造出
    /// 四态、其中「未同意+已测麦」不可能态靠两处同时置位的约定避免——
    /// 枚举使不可能态不可表达，隐私卡绝不因疏忽被跳过）
    private enum InterviewPhase { case consent, micCheck, interview }

    @State private var phase: InterviewPhase = .consent
    @State private var stepIndex = 0
    @State private var answer = ""
    @State private var confirmSet: OcrConfirmationSet?
    @State private var rejection: VoiceModificationGuard.Rejection?
    @State private var routeMonitor = AudioRouteMonitor()
    @State private var saveFailed = false
    @State private var dictationBusy = false
    @State private var dictationScope = UUID()
    @State private var committing = false
    @State private var dictationConfidence: Double = 1

    var body: some View {
        Group {
            if phase == .consent && !voiceConsentRecorded {
                // FR17.12：进入访谈前的一次性隐私与耳机须知
                VoicePrivacyHeadphoneCard(
                    onAccept: { recordVoiceConsent(); phase = .micCheck },
                    // 审查修复：触屏入口此前是死路（__useTouch 提交被
                    // markVoiceInterviewStep 白名单拒绝，卡面原地不动）——
                    // 实际语义 = 跳过语音自检、直接以键盘输入继续访谈
                    onUseTouch: { recordVoiceConsent(); phase = .interview })
            } else if phase != .interview {
                // TestFlight 实测修复：语音访谈前先做音量自检（实时音量条 +
                // 测试句朗读指导），低音量可重试、无障碍用户可跳过保留手输
                VoiceLevelCheck(
                    onPass: { phase = .interview },
                    onSkip: { phase = .interview })
            } else {
                interview
            }
        }
        .navigationTitle(L10n.voiceguide_profileTitle)
        .voiceConfirmSheet($confirmSet, route: routeMonitor.route) { confirmed in
            confirmSet = nil
            Task { await commitFields(confirmed) }
        }
        .sheet(item: Binding(get: { rejection.map(RejectionBox.init) },
                             set: { if $0 == nil { rejection = nil } })) { box in
            VoiceModificationRejectionCard(
                rejection: box.value,
                onGoToPlan: {
                    rejection = nil
                    Task { _ = await onCommitField("__goToPlan", "1") }
                },
                onDismiss: { rejection = nil; answer = "" })
            .presentationDetents([.height(260)])
        }
        .alert(L10n.voicenoteSaveFailed, isPresented: $saveFailed) {
            Button(L10n.onboard_gotIt, role: .cancel) { }
        }
        .onAppear {
            routeMonitor.start()
            // FR17.9 §5.54：语音面板确认后的档案草稿一次性预填（与提醒入口同款）
            if let draft = router.pendingVoiceIntent {
                router.pendingVoiceIntent = nil
                if answer.isEmpty,
                   let v = draft.keyedValues.values.first(where: { !$0.isEmpty }) {
                    answer = v
                }
            }
        }
        .onDisappear { routeMonitor.stop() }
    }

    /// FR17.12 一次性语义：确认即写 ConsentRecord（F20.5 判定重展）——
    /// 此前只置视图内 @State，每次进入都重展且无落库
    private var voiceConsentRecorded: Bool {
        DisclosureRegistry.isConfirmed(scene: "voice_session", consents: app.consentRecords)
    }

    private func recordVoiceConsent() {
        guard let d = DisclosureRegistry.l2Disclosures.first(where: { $0.scene == "voice_session" }) else { return }
        Task { await app.recordConsent(key: d.key, level: d.level, version: d.version) }
    }

    /// 确认后逐字段落库；任一失败即停下并可见报错（审查修复：此前
    /// updateMember 的 Bool 被 `_ =` 丢弃，写失败仍推进下一步）
    private func commitFields(_ set: OcrConfirmationSet) async {
        guard !committing else { return }
        committing = true
        defer { committing = false }
        var allOK = true
        for field in set.confirmedFields {
            if !(await onCommitField(field.key, field.value)) { allOK = false; break }
        }
        guard allOK else {
            saveFailed = true
            return
        }
        dictationScope = UUID()
        dictationBusy = false
        dictationConfidence = 1
        answer = ""
        if stepIndex + 1 < steps.count { stepIndex += 1 }
    }

    private var interview: some View {
        let key = steps[stepIndex].key
        let scope = dictationScope
        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.voiceguideStep(stepIndex + 1, steps.count))
                .font(.caption).foregroundStyle(.secondary)
            Text(steps[stepIndex].prompt)
                .font(.headline)
                .accessibilityIdentifier("FR17.11.prompt")
            // TestFlight 实测修复：提问自动语音朗读（不看屏幕也能访谈），
            // 每次进入新步骤重读一遍；听写按钮接同一回答输入（可手输可语音）
            VoiceDictationButton(onTranscript: { text, confidence in
                guard dictationScope == scope, steps[stepIndex].key == key, !text.isEmpty else { return }
                dictationConfidence = min(dictationConfidence, confidence)
                answer = answer.isEmpty ? text : answer + "\n" + text
            }, isBusy: Binding(get: { dictationBusy }, set: { busy in
                if dictationScope == scope, steps[stepIndex].key == key { dictationBusy = busy }
            }))
            .id(scope)
            .disabled(committing)
            TextField(L10n.voiceguide_answerHint, text: $answer, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(committing)
                .accessibilityIdentifier("FR17.11.answer")
            HStack(spacing: 12) {
                Button(L10n.voiceguide_skip) {
                    dictationScope = UUID()
                    dictationBusy = false
                    dictationConfidence = 1
                    answer = ""
                    if stepIndex + 1 < steps.count { stepIndex += 1 }
                }
                .frame(minHeight: 44)
                .disabled(committing)
                .accessibilityIdentifier("FR17.11.skip")
                Spacer()
                Button(L10n.voiceguide_next) { buildDraft() }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .disabled(committing || dictationBusy || answer.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("FR17.11.next")
            }
            Spacer()
        }
        .padding(16)
        // TestFlight 实测修复：提问自动朗读——进入访谈与每次换步都读一遍
        .onAppear { app.speak(steps[stepIndex].prompt) }
        .onChange(of: stepIndex) { _, newStep in
            app.speak(steps[newStep].prompt)
        }
    }

    private func buildDraft() {
        guard !dictationBusy, !committing else { return }
        let text = answer.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        // BR-003/006：语音通道对既有计划的剂量/频次/停用修改一律拒绝。
        // 「当前服药」步骤即处于既有计划语境，其余步骤不拦（否则连备忘都记不了）。
        let planContext = steps[stepIndex].key == "currentMeds"
        if let r = VoiceModificationGuard.evaluate(text, isExistingPlanContext: planContext) {
            rejection = r
            return
        }
        // FR17.13-entry: 语音指导 —— 走统一模板，不自建确认逻辑
        confirmSet = VoiceInputTemplate.confirmationSet(drafts: [
            FieldDraft(key: steps[stepIndex].key, value: text, confidence: min(0.88, dictationConfidence))
        ])
    }
}

/// `sheet(item:)` 要求 Identifiable；Rejection 是纯值规则对象，不该为了 UI 承担 ID，
/// 故在 UI 层包一层（同 OcrConfirmationSet 的处理取向）。
private struct RejectionBox: Identifiable {
    let value: VoiceModificationGuard.Rejection
    init(_ value: VoiceModificationGuard.Rejection) { self.value = value }
    var id: String { "\(value.category.rawValue)|\(value.matchedPhrase)" }
}
