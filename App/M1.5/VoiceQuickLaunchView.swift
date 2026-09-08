import SwiftUI
import Domain
import Infrastructure
import Protocols

/// FR17.9 全局语音快速入口（SP-55 语音速记面板 · ui-ux §5.54）：
/// **去 chips（V3.49 位置迁移）**——面板不再常驻渲染去向选择器，识别后文本
/// 经共享文本理解层（FR17.18）自动判定意图/字段，「判定结果行」以 D 级草稿
/// 呈现于 FR17.13 确认卡头部（Menu 可改类）；分类低置信/无法判定时确认卡内
/// 以候选去向行内联引导（仅该状态渲染，不常驻）。仅限受限文法与结构化
/// 录入，不做自由对话（F19 边界延续）。
///
/// **§5.54 契约**：按住说话（波形+实时转写）→ 本地理解层自动判定
/// → FR17.13 统一确认模板（判定结果行+逐字段确认）→ 按判定意图分发
/// （未知/速记 = 面板内直接落 VoiceNote；其余 = pendingVoiceIntent 暂存后
/// 跳转目标页预填）。
struct VoiceQuickLaunchView: View {
    @Environment(AppState.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(VoiceNoteState.self) private var voiceNoteState
    @Environment(\.dismiss) private var dismiss

    @State private var confirmSet: OcrConfirmationSet?
    @State private var savedNote = false
    @State private var routeMonitor = AudioRouteMonitor()
    /// 理解层判定意图（FR17.19 目录 key；D 级，确认卡判定结果行呈现/可改）
    @State private var judgedIntent: String?
    @State private var judgedConfidence: Double = 0
    /// 最近一次转写（Menu 改类后按新意图重抽槽位用）
    @State private var lastTranscript: (text: String, confidence: Double)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(L10n.voicePanelTitle)
                    .font(.title2.bold())
                // V3.49 去 chips 后的能力诚实标注：去向由本地理解层自动判定
                Text(L10n.voicePanelAutoHint)
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                // §5.54 中部录音环节：按住说话 + 实时转写（组件自带部分文本/失败态/
                // 授权关闭回落提示）；完成回调经理解层自动判定意图与槽位
                // FR17.13-entry: 语音速记面板 —— 统一确认模板，不自建确认逻辑
                VoiceDictationButton { text, confidence in
                    // BR-012 紧急关键词前置（V3.40 语音指令入口，复用 F12 词表
                    // 单一事实源）：命中即急救卡、终止解析——「我胸闷」绝不
                    // 落速记或指标草稿
                    if EmergencyKeywordRules.match(text) {
                        dismiss()
                        router.navigate(to: .emergencyCardConfig)
                        return
                    }
                    lastTranscript = (text, confidence)
                    Task { await understand(text: text, confidence: confidence) }
                }
                .padding(.horizontal, 24)
                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle(L10n.voicePanelTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
                // FR17.15 面板内语言入口（5.54 C）——跳语音语言选择器
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        VoiceLanguageSettingsView()
                    } label: {
                        Image(systemName: "globe")
                    }
                    .accessibilityIdentifier("SP-55.panel.language")
                }
            }
            .onAppear { routeMonitor.start() }
            .onDisappear { routeMonitor.stop() }
            .voiceConfirmSheet($confirmSet, route: routeMonitor.route,
                               judgedTarget: judgedIntent,
                               judgedConfidence: judgedConfidence,
                               onJudgedTargetChange: { newKey in
                // 确认卡 Menu/候选行改类：按新意图重抽槽位（期一无独立文法
                // 的意图回落纯文本草稿——FR17.19 消歧兜底语义，不静默丢内容）
                guard let transcript = lastTranscript else { return }
                judgedIntent = newKey
                judgedConfidence = 0.9
                let key = VoiceIntentKey(rawValue: newKey) ?? .unknown
                let drafts = VoiceIntentCatalog.extract(for: key, text: transcript.text,
                                                        confidence: transcript.confidence)
                let newSet = VoiceInputTemplate.confirmationSet(
                    drafts: drafts, documentId: confirmSet?.documentId ?? UUID())
                confirmSet = newSet
            }) { confirmed in
                confirmSet = nil
                dispatch(confirmed)
            }
            .alert(L10n.voicePanelSaved, isPresented: $savedNote) {
                Button(L10n.voicenoteView) {
                    // 审查修复：跳转前必须先收起本面板 sheet——router.navigate
                    // 只切 Tab/推路径，不收起已呈现的 sheet，「查看」按钮此前
                    // 在面板之下切页、视觉无任何变化，用户只能手动关闭。
                    dismiss()
                    router.navigate(to: .voiceNotePanel)
                }
                Button(L10n.onboard_gotIt, role: .cancel) {}
            }
        }
        .presentationDetents([.medium])
    }

    /// 共享文本理解层自动判定（FR17.18 期一：兜底轨文法/启发式）——
    /// 单次调用产出意图 + 槽位草稿，替代此前三套正则并行抽取的内联实现
    private func understand(text: String, confidence: Double) async {
        let understanding = EngineRegistry.shared.resolve(TextUnderstandingFactory.self)
        let result = await understanding.understand(
            TextUnderstandingInput(text: text, source: .voice(intentHint: nil)))
        judgedIntent = result.suggestedTarget
        judgedConfidence = result.targetConfidence
        confirmSet = VoiceInputTemplate.confirmationSet(drafts: result.fields)
    }

    /// 意图 key → 分发目标（期一可分发集合；未知/速记 = anyText）
    private func target(for intent: String?) -> L10n.TargetTag {
        switch intent {
        case VoiceIntentKey.recordMetric.rawValue: return .metric
        case VoiceIntentKey.recordObservation.rawValue: return .observation
        case VoiceIntentKey.createReminder.rawValue: return .reminder
        case VoiceIntentKey.appendProfile.rawValue: return .profile
        case VoiceIntentKey.askAssistant.rawValue: return .ai
        case VoiceIntentKey.createQuestion.rawValue: return .question
        default: return .anyText   // appendNote/unknown/无法判定 → 语音速记兜底
        }
    }

    /// 确认后分发（§5.54）：任意文本 = 面板内落 VoiceNote + 已存提示（[查看]
    /// 直达 SP-59）；其余目标 = 类型化 pendingVoiceIntent 暂存后跳目标页预填。
    /// 分发目标 = 确认卡定夺的判定意图（FR17.9「不预选数据去向」）。
    private func dispatch(_ set: OcrConfirmationSet) {
        let fields = set.confirmedFields
        let target = target(for: judgedIntent)
        switch target {
        case .anyText:
            guard let body = fields.first?.value, !body.isEmpty else { return }
            Task {
                // 审查修复：写失败不得弹「已保存」——create 返回成败，
                // [查看] 直达的列表里没有这条速记会当场露馅（假事实）
                savedNote = await voiceNoteState.create(patientId: app.currentPatientId, body: body, tags: nil)
            }
        case .observation, .question, .ai:
            // 无预填消费方的意图：直接打开目标页（无暂存草稿——写暂存只会
            // 滞留并被下一次快速录入误消费）
            open(target)
            dismiss()
        case .metric, .reminder, .profile:
            // 类型化一次性投递（coreml §8.2：pendingVoiceIntent）
            router.pendingVoiceIntent = set.pendingIntent(judgedIntent ?? VoiceIntentKey.unknown.rawValue)
            open(target)
            dismiss()
        }
    }

    private func open(_ target: L10n.TargetTag) {
        switch target {
        case .metric: router.navigate(to: .metricQuickEntry)
        case .observation: router.navigate(to: .observationCreate)
        case .question: router.navigate(to: .questionList)
        case .ai: router.navigate(to: .assistantChat)
        case .reminder: router.navigate(to: .voiceReminderDraft)
        case .profile: router.navigate(to: .voiceGuideProfile)
        case .anyText: router.navigate(to: .voiceNotePanel)
        }
    }
}
