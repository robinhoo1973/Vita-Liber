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
///
/// **V3.94 全屏工作台（improving-requirements 1.2 / tech V3.93 口径修正）**：
/// 上方 = 转写文本编辑区（点击直接编辑，续录追加）；下方 = 操作区
/// （长按录音/松手停止，再次长按续录；清除最近一次/全部——最近为默认）。
/// 「LLM 修正版」切换随主轨（期三 Foundation Models）落地后接入本页面
/// （能力诚实标注：期一只呈现原生转译版，已登记 §11）。
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
    /// 转写代次（tech V3.92「过期异步结果丢弃」契约）：每次新转写/Menu 改类
    /// +1；understand 写回前与当前代次比较、不匹配即丢弃——快速连录时旧
    /// 会话的慢理解结果不得覆盖新会话的判定/草稿（用户确认的可能是旧文本）
    @State private var transcriptGeneration = 0
    /// 全屏工作台（1.2）：转写段历史（续录追加；清除最近一次 = pop 末段）
    @State private var segments: [String] = []
    /// 编辑区当前文本（= segments 按行连接，可点击直接编辑）
    @State private var accumulatedText = ""
    /// 清除选择框呈现
    @State private var showClearDialog = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // 上方 = 转写文本显示区（1.2）：实时追加、点击直接编辑
                TextEditor(text: $accumulatedText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(Color("bg-grouped", bundle: .main)))
                    .overlay {
                        if accumulatedText.isEmpty {
                            Text(L10n.voicePanelEditHint)
                                .font(.footnote).foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                                .padding(12)
                        }
                    }
                    .accessibilityIdentifier("SP-55.panel.transcript")
                // 下方 = 操作按钮区（1.2）：长按录音/松手停止；再次长按续录
                // BR-012 前置已下沉组件内（onEmergencyAction 注入「先收起全屏
                // 再跳急救卡」——默认动作不收起，急救卡会被本面板盖住）；
                // 组件未拦截的文本走续录追加
                VoiceDictationButton(onEmergencyAction: { _ in
                    dismiss()
                    router.navigate(to: .emergencyCardConfig)
                }) { text, confidence in
                    appendSegment(text, confidence: confidence)
                }
                .padding(.horizontal, 24)
                HStack(spacing: 12) {
                    Button {
                        showClearDialog = true
                    } label: {
                        Label(L10n.voicePanelClear, systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(segments.isEmpty)
                    .accessibilityIdentifier("SP-55.panel.clear")
                    Button {
                        Task { await confirmFromTranscript() }
                    } label: {
                        Label(L10n.voicePanelConfirm, systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("SP-55.panel.confirm")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)
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
            // 清除选择框（1.2）：清除最近一次为默认选项
            .confirmationDialog(L10n.voicePanelClearTitle, isPresented: $showClearDialog,
                                titleVisibility: .visible) {
                Button(L10n.voicePanelClearLast, role: .destructive) {
                    clearLastSegment()
                }
                Button(L10n.voicePanelClearAll, role: .destructive) {
                    clearAllSegments()
                }
                Button(L10n.commonCancel, role: .cancel) {}
            }
            .voiceConfirmSheet($confirmSet, route: routeMonitor.route,
                               judgedTarget: judgedIntent,
                               judgedConfidence: judgedConfidence,
                               onJudgedTargetChange: { newKey in
                // 确认卡 Menu/候选行改类：按新意图重抽槽位（期一无独立文法
                // 的意图回落纯文本草稿——FR17.19 消歧兜底语义，不静默丢内容）。
                // 重抽输入 = 编辑区当前文本（用户可能已编辑，转写原件不再权威）；
                // 编辑区被清空时不重抽——空文本会产出零字段确认集，把用户
                // 正在确认的草稿整个抹掉
                let source = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty else { return }
                transcriptGeneration += 1   // 改类使在途理解结果全部失效
                judgedIntent = newKey
                judgedConfidence = 0.9
                let key = VoiceIntentKey(rawValue: newKey) ?? .unknown
                let drafts = VoiceIntentCatalog.extract(for: key, text: source,
                                                        confidence: lastTranscript?.confidence ?? 0.9)
                let newSet = VoiceInputTemplate.confirmationSet(
                    drafts: drafts, documentId: confirmSet?.documentId ?? UUID())
                confirmSet = newSet
            }) { confirmed in
                confirmSet = nil
                // 先分发后归零：dispatch 按 judgedIntent 定目标、pendingVoiceIntent
                // 携带确认值——clearAllSegments 会重置 judgedIntent，先清即
                // 全部落入 anyText 兜底（指标/提醒/档案预填失效）
                dispatch(confirmed)
                clearAllSegments()
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
    }

    // MARK: - 全屏工作台段管理（1.2）

    /// 续录追加：编辑区是唯一事实源——此前 segments 重连会覆盖用户的全部
    /// 手编辑内容（改错字后续录即丢）；segments 由编辑区按行派生，仅用于
    /// 「清除最近一次」的粒度
    private func appendSegment(_ text: String, confidence: Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcriptGeneration += 1
        lastTranscript = (text, confidence)
        accumulatedText = accumulatedText.isEmpty
            ? trimmed
            : accumulatedText + "\n" + trimmed
        segments = accumulatedText.components(separatedBy: "\n")
    }

    /// 清除最近一次录音（1.2 默认选项）
    private func clearLastSegment() {
        guard !segments.isEmpty else { return }
        transcriptGeneration += 1
        segments.removeLast()
        accumulatedText = segments.joined(separator: "\n")
        confirmSet = nil
    }

    /// 清除全部录音（1.2）：工作台归零
    private func clearAllSegments() {
        transcriptGeneration += 1
        segments = []
        accumulatedText = ""
        confirmSet = nil
        judgedIntent = nil
        judgedConfidence = 0
    }

    /// 确认：以编辑区当前文本过理解层（编辑后文本即判定输入——转写只是草料）
    private func confirmFromTranscript() async {
        let text = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        transcriptGeneration += 1
        let generation = transcriptGeneration
        await understand(text: text, confidence: lastTranscript?.confidence ?? 0.9,
                         generation: generation)
    }

    /// 共享文本理解层自动判定（FR17.18 期一：兜底轨文法/启发式）——
    /// 单次调用产出意图 + 槽位草稿，替代此前三套正则并行抽取的内联实现。
    /// 转写置信度随输入传递（此前在此处被丢弃、引擎恒按 0.9 分类）
    private func understand(text: String, confidence: Double, generation: Int) async {
        let understanding = EngineRegistry.shared.resolve(TextUnderstandingFactory.self)
        let result = await understanding.understand(
            TextUnderstandingInput(text: text,
                                   source: .voice(intentHint: nil, confidence: confidence)))
        // 过期异步结果丢弃（V3.92）：写回前校验代次——乱序完成的理解结果
        // 不得覆盖新会话判定（含用户 Menu 改类后的意图）
        guard generation == transcriptGeneration else { return }
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
