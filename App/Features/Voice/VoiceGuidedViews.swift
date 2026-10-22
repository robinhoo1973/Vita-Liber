import SwiftUI
import Domain
import Protocols
import Perception

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
    let onCommit: (_ title: String, _ fireAt: Date, _ repeatRule: String?,
                   _ audit: VoiceExecutionAudit?) async -> Bool

    @State private var transcript = ""
    /// 助手交接的审计身份（V12/V13）；手动进入为 nil。
    @State private var voiceAudit: VoiceExecutionAudit?
    @State private var confirmSet: OcrConfirmationSet?
    @State private var routeMonitor = AudioRouteMonitor()
    @State private var unresolved: String?
    @State private var savedAlert = false
    @State private var dictationBusy = false
    @State private var dictationScope = UUID()
    @State private var dictationConfidence: Double = 1

    var body: some View {
        WithPerceptionTracking {
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
                // 确认字段回填转写输入，本页二次核对后走本页自己的确认。
                // V11：意图/患者不匹配即丢弃，绝不跨成员预填。
                if let draft = router.pendingVoiceIntent,
                   draft.intent != VoiceIntentKey.createReminder.rawValue
                    || (draft.patientId != nil && draft.patientId != app.currentPatientId) {
                    router.pendingVoiceIntent = nil
                }
                if let draft = router.pendingVoiceIntent {
                    router.pendingVoiceIntent = nil
                    voiceAudit = draft.executionAudit()
                    if transcript.isEmpty {
                        // content 与时间槽必须同时进入正文：聊天补槽后 content 恒存在，
                        // 旧实现只在 content 缺失时才重组时间，已确认的 date/hour/time
                        // 会被静默丢弃。两部分拼接后由本页重新抽取（FR17.10）。
                        let content = draft.keyedValues["content"] ?? draft.keyedValues["note"] ?? ""
                        let time = VoiceInputTemplate.reminderTranscript(from: draft.fields)
                        let parts = [content, time].filter { !$0.isEmpty }
                        if !parts.isEmpty { transcript = parts.joined(separator: " ") }
                    }
                }
            }
            .onDisappear { routeMonitor.stop() }
            .alert(L10n.voiceguide_saved, isPresented: $savedAlert) {
                Button(L10n.onboard_gotIt, role: .cancel) { }
            }
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
        dictationBusy = false
        dictationConfidence = 1
        // 审查修复：清稿必须等落库结果——此前先清 transcript 再 await 调度，
        // 失败时用户口述的完整提醒文本已被抹掉、必须重录（可见失败 + 文本
        // 丢失双重打击）。成功才清稿。
        // 审查修复：调度失败必须可见（此前后台吞错 + 无条件弹「已保存」，
        // 用户以为提醒已设置——通知权限被拒/调度抛错时提醒永不触发）
        let ok = await onCommit(title, fireAt, rule, voiceAudit)
        if ok {
            voiceAudit = nil
            dictationScope = UUID()
            transcript = ""
            savedAlert = true   // TestFlight 实测修复：保存后必须有可见反馈（引导用户知道提醒已设置）
        } else {
            unresolved = L10n.voiceReminderSaveFailed
        }
    }
}
