import SwiftUI
import Domain
import Protocols

/// FR17.10 语音提醒设定 + FR17.11 语音引导式档案注册/完善（SP-58）。
/// 两者的确认一律走 `VoiceConfirmSheet`（FR17.13），本文件不含任何自建确认 UI。

// MARK: - FR17.10 语音提醒设定

/// 一句话说出提醒 → 文法抽取时间/重复 → 统一模板确认 → 入 Reminder 实体。
struct VoiceReminderDraftView: View {
    @Environment(AppState.self) private var app
    let onCommit: (_ title: String, _ fireAt: Date, _ repeatRule: String?) -> Void

    @State private var transcript = ""
    @State private var confirmSet: OcrConfirmationSet?
    @State private var routeMonitor = AudioRouteMonitor()
    @State private var unresolved: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.voiceguide_reminderTitle).font(.headline)
            Text(L10n.voiceguide_reminderExample)
                .font(.caption).foregroundStyle(.secondary)
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
            .disabled(transcript.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("FR17.10.build")
            Spacer()
        }
        .padding(16)
        .sheet(item: $confirmSet) { set in
            VoiceConfirmSheet(
                set: set,
                decision: ReadbackPolicy.decide(route: routeMonitor.route,
                                                preference: app.readbackPreference,
                                                careMode: app.careMode),
                onSpeak: { app.speak($0) },
                onConfirm: { confirmed in
                    commit(confirmed)
                    confirmSet = nil
                },
                onRetry: { confirmSet = nil },
                onCancel: { confirmSet = nil })
            .presentationDetents([.medium])
        }
        .onAppear { routeMonitor.start() }
        .onDisappear { routeMonitor.stop() }
    }

    private func buildDraft() {
        unresolved = nil
        let drafts = VoiceStructuringEngine.extractReminder(transcript, rules: VoiceGrammarDefaults.reminderRules)
        guard !drafts.isEmpty else {
            unresolved = L10n.voiceReminderTimeUnheard
            return
        }
        // 模糊时间必须落成具体日期后才允许确认（FR17.10：草稿逐字段可改）
        guard VoiceReminderRules.resolveDate(from: drafts, now: Date()) != nil else {
            unresolved = L10n.voiceReminderTimeUnclear
            return
        }
        // FR17.13-entry: 提醒草稿 —— 走统一模板，不自建确认逻辑
        confirmSet = VoiceInputTemplate.confirmationSet(drafts: drafts)
    }

    private func commit(_ set: OcrConfirmationSet) {
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
        transcript = ""
        onCommit(title, fireAt, rule)
    }
}

// MARK: - FR17.11 语音引导式档案（SP-58）

/// 「系统问一步、用户答一步」的档案访谈。每步答案 → 统一模板确认 → 写入档案字段。
/// 对既有用药计划的剂量/频次/停用修改一律弹拒绝卡（BR-003/006）。
struct VoiceGuidedProfileView: View {
    @Environment(AppState.self) private var app
    let onCommitField: (_ key: String, _ value: String) -> Void

    /// 访谈步骤（FR17.11 + FR3.1 紧急联系人基础字段随本条提前至 P0.5）
    private let steps: [(key: String, prompt: String)] = [
        ("allergy", L10n.voiceguide_promptAllergy),
        ("pastHistory", L10n.voiceguide_promptHistory),
        ("currentMeds", L10n.voiceguide_promptMeds),
        ("emergencyContact", L10n.voiceguide_promptContact),
    ]

    @State private var consentGiven = false
    @State private var micChecked = false
    @State private var stepIndex = 0
    @State private var answer = ""
    @State private var confirmSet: OcrConfirmationSet?
    @State private var rejection: VoiceModificationGuard.Rejection?
    @State private var routeMonitor = AudioRouteMonitor()

    var body: some View {
        Group {
            if !consentGiven {
                // FR17.12：进入访谈前的一次性隐私与耳机须知
                VoicePrivacyHeadphoneCard(
                    onAccept: { consentGiven = true },
                    onUseTouch: { onCommitField("__useTouch", "1") })
            } else if !micChecked {
                // TestFlight 实测修复：语音访谈前先做音量自检（实时音量条 +
                // 测试句朗读指导），低音量可重试、无障碍用户可跳过保留手输
                VoiceLevelCheck(
                    onPass: { micChecked = true },
                    onSkip: { micChecked = true })
            } else {
                interview
            }
        }
        .navigationTitle(L10n.voiceguide_profileTitle)
        .sheet(item: $confirmSet) { set in
            VoiceConfirmSheet(
                set: set,
                decision: ReadbackPolicy.decide(route: routeMonitor.route,
                                                preference: app.readbackPreference,
                                                careMode: app.careMode),
                onSpeak: { app.speak($0) },
                onConfirm: { confirmed in
                    for field in confirmed.confirmedFields { onCommitField(field.key, field.value) }
                    confirmSet = nil
                    answer = ""
                    if stepIndex + 1 < steps.count { stepIndex += 1 }
                },
                onRetry: { confirmSet = nil },
                onCancel: { confirmSet = nil })
            .presentationDetents([.medium])
        }
        .sheet(item: Binding(get: { rejection.map(RejectionBox.init) },
                             set: { if $0 == nil { rejection = nil } })) { box in
            VoiceModificationRejectionCard(
                rejection: box.value,
                onGoToPlan: { rejection = nil; onCommitField("__goToPlan", "1") },
                onDismiss: { rejection = nil; answer = "" })
            .presentationDetents([.height(260)])
        }
        .onAppear { routeMonitor.start() }
        .onDisappear { routeMonitor.stop() }
    }

    private var interview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.voiceguideStep(stepIndex + 1, steps.count))
                .font(.caption).foregroundStyle(.secondary)
            Text(steps[stepIndex].prompt)
                .font(.headline)
                .accessibilityIdentifier("FR17.11.prompt")
            // TestFlight 实测修复：提问自动语音朗读（不看屏幕也能访谈），
            // 每次进入新步骤重读一遍；听写按钮接同一回答输入（可手输可语音）
            VoiceDictationButton { text, _ in
                if !text.isEmpty { answer = text }
            }
            TextField(L10n.voiceguide_answerHint, text: $answer, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .accessibilityIdentifier("FR17.11.answer")
            HStack(spacing: 12) {
                Button(L10n.voiceguide_skip) {
                    answer = ""
                    if stepIndex + 1 < steps.count { stepIndex += 1 }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("FR17.11.skip")
                Spacer()
                Button(L10n.voiceguide_next) { buildDraft() }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
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
            FieldDraft(key: steps[stepIndex].key, value: text, confidence: 0.88)
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
