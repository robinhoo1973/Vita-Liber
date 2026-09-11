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
/// Optional Foundation Models formatting is separate from the NL/regex understanding track.
/// Changed suggestions remain preview-only until storage can retain their native provenance.
@MainActor
struct VoiceQuickLaunchView: View {
    @Environment(AppState.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(VoiceNoteState.self) private var voiceNoteState
    @Environment(AppSettingsStore.self) private var settings
    @Environment(M2HubStore.self) private var hub
    @Environment(\.dismiss) private var dismiss

    @State private var confirmSet: OcrConfirmationSet?
    @State private var savedNote = false
    @State private var routeMonitor = AudioRouteMonitor()
    /// 理解层判定意图（FR17.19 目录 key；D 级，确认卡判定结果行呈现/可改）
    @State private var judgedIntent: String?
    @State private var judgedConfidence: Double = 0
    /// Latest recognition confidence; full native text belongs to transcript, not this tuple.
    @State private var lastTranscript: (text: String, confidence: Double)?
    @State private var transcript = TranscriptRefinementState()
    @State private var confirmationSource: TranscriptSourceSnapshot?
    @State private var confirmationPatientID: UUID?
    @State private var refinementTask: Task<Void, Never>?
    @State private var understandingTask: Task<Void, Never>?
    @State private var isUnderstanding = false
    @State private var isSaving = false
    @State private var failedDispatch: OcrConfirmationSet?
    @State private var showSaveFailure = false
    /// 清除选择框呈现
    @State private var showClearDialog = false
    /// 转写模型（§4.23 中部大号按住说话按钮持有——本页唯一实例，
    /// 同一引擎单会话；环境就绪后装配，同 VoiceDictationButton 纪律）
    @State private var model: VoiceDictationModel?

    // FR17.9/FR17.18 V3.61 双版本：原生转译版 / LLM 修正版（仅 authAI 开且端侧模型可用时呈现）
    @State private var refinerAvailable = false

    private var refinerEnabled: Bool { settings.values[.authAI] != "false" && refinerAvailable }
    private var accumulatedText: String { transcript.nativeText }
    private var transcriptVersion: TranscriptVersion { transcript.version }
    private var revision: TranscriptRevision? { transcript.revision }
    private var refining: Bool { transcript.isRefining }
    private var sourceSnapshot: TranscriptSourceSnapshot {
        // The settings owner increments this epoch synchronously, including coalesced revoke/regrant.
        transcript.snapshot(authorized: refinerEnabled, authorizationGeneration: settings.authAIRevision)
    }
    private var effectiveText: String { sourceSnapshot.selectedText }
    private var previewOnly: Bool { sourceSnapshot.requiresOriginalPersistence }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // §4.23 纵向稳定分区：中部 = 大号按住说话按钮 + 声波/聆听状态
                // （业主反馈：此前仅底部普通按钮，无图形录入入口）
                if settings.values[.authVoiceDictation] == "false" {
                    Label(L10n.privacyAuthVoiceDisabled, systemImage: "mic.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("voice.dictation.authDisabled")
                } else if let model {
                    // BR-012 前置在模型内统一执行（onEmergency 装配见
                    // ensureModel：命中即收起全屏跳急救卡，不被本面板盖住）
                    PressToTalkMicButton(model: model)
                        .disabled(isSaving || isUnderstanding || confirmSet != nil)
                    Text(L10n.voiceEngineName(model.resolvedEngineID.flatMap(VoiceEngineChoice.init(rawValue:))
                        ?? VoiceEngineChoice.resolve(settings.values[.voiceEngine])))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("SP-55.panel.engine")
                    // FR17.15 能力诚实（V3.61）：回显实际识别语言；方言回落主语言时标「尽力识别」
                    if let resolved = model.resolvedLocale {
                        HStack(spacing: 6) {
                            Text(L10n.voiceRecognizedAs(resolved))
                            if model.isBestEffortFallback {
                                Text(L10n.voiceLangBestEffort)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color(.systemGray5)))
                            }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("SP-55.panel.resolvedLocale")
                    }
                }
                // 转写文本显示区（1.2）：实时追加、点击直接编辑
                TextEditor(text: Binding(get: { accumulatedText }, set: { editTranscript($0) }))
                    .disabled(isSaving)
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
                // FR17.9 V3.61 双版本分段控件：默认原生；修正版 D 级「仅作文字清理」；
                // 不可用/超时/校验失败只显示原文 + 轻提示（不阻断保存）
                if refinerEnabled && !accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker(L10n.voiceVersionNative,
                               selection: Binding(get: { transcriptVersion }, set: { selectVersion($0) })) {
                            Text(L10n.voiceVersionNative).tag(TranscriptVersion.native)
                            Text(L10n.voiceVersionRefined).tag(TranscriptVersion.refined)
                        }
                        .pickerStyle(.segmented)
                        .disabled(isSaving)
                        .accessibilityIdentifier("SP-55.panel.version")
                        if transcriptVersion == .refined {
                            HStack(spacing: 6) {
                                GradeBadge(grade: "D")
                                if refining {
                                    ProgressView().controlSize(.small)
                                } else if let revision, revision.original == accumulatedText {
                                    switch revision.safety {
                                    case .accepted: Text(L10n.voiceVersionRefinedHint)
                                    case .rejected: Text(L10n.voiceVersionRejected)
                                    case .unavailable, .timedOut: Text(L10n.voiceVersionUnavailable)
                                    }
                                }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityIdentifier("SP-55.panel.versionHint")
                            if let revision, sourceSnapshot.version == .refined,
                               WordingBlacklist.violation(in: revision.suggested) == nil {
                                Text(effectiveText)
                                    .font(.body)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 12)
                                        .fill(Color("bg-grouped", bundle: .main)))
                                    .accessibilityIdentifier("SP-55.panel.refinedText")
                            }
                            if previewOnly {
                                Text(L10n.voiceVersionPreviewOnly)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("SP-55.panel.refinedPreviewOnly")
                                Button(L10n.voiceVersionNative) { selectVersion(.native) }
                                    .disabled(isSaving)
                            } else if !refining, revision?.safety != .accepted {
                                Button(L10n.retry) { refineCurrentText() }
                                    .disabled(isSaving || isUnderstanding)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
                if showSaveFailure {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.voicenoteSaveFailed).font(.caption)
                        Button(L10n.retry) { retryDispatch() }
                            .disabled(isSaving)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .accessibilityIdentifier("SP-55.panel.saveFailure")
                }
                // 下方 = 操作按钮区（1.2）：清除/确认；录音入口已上移至中部
                // 大号按住说话按钮（PressToTalkMicButton，§4.23）——再次
                // 长按即续录（V3.94 口径）
                HStack(spacing: 12) {
                    Button {
                        showClearDialog = true
                    } label: {
                        Label(L10n.voicePanelClear, systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(accumulatedText.isEmpty || isSaving)
                    .accessibilityIdentifier("SP-55.panel.clear")
                    Button {
                        confirmFromTranscript()
                    } label: {
                        Label(L10n.voicePanelConfirm, systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || isSaving || isUnderstanding || previewOnly || model?.hasPendingTranscriptions == true)
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
                        .disabled(isSaving)
                }
                // FR17.15 面板内语言入口（5.54 C）——跳语音语言选择器
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        VoiceLanguageSettingsView()
                    } label: {
                        Image(systemName: "globe")
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("SP-55.panel.language")
                }
            }
            .onAppear { routeMonitor.start() }
            .onDisappear {
                routeMonitor.stop()
                model?.stopForDisappear()   // 视图销毁即终止在途听写投递
                stopRefinement()
                transcript.revokeAI()
                invalidateConfirmation()
            }
            // 引擎在环境就绪后装配（同 VoiceDictationButton 纪律：语言值变化
            // 即重建，面板内改语言返回后 preferredLocale 即时生效）
            .task(id: "\(settings.values[.voiceInputLanguages] ?? "")|\(settings.values[.voiceMixedInput] ?? "")") { ensureModel() }
            .onChange(of: settings.values[.authAI]) { _, value in
                if value == "false" { revokeRefinement() }
            }
            .onChange(of: settings.authAIRevision) { _, _ in revokeRefinement() }
            .onChange(of: refinerAvailable) { _, available in
                if !available { revokeRefinement() }
            }
            .onChange(of: app.currentPatientId) { _, _ in
                stopRefinement()
                transcript.revokeAI()
                invalidateConfirmation()
            }
            .task {
                // 能力探测（编译期 canImport + 运行期 availability；不含授权——授权由 authAI 门控）
                let available = await app.textRefiner.isAvailable
                guard !Task.isCancelled else { return }
                refinerAvailable = available
            }
            // 清除选择框（1.2）：清除最近一次为默认选项
            .confirmationDialog(L10n.voicePanelClearTitle, isPresented: $showClearDialog,
                                titleVisibility: .visible) {
                Button(L10n.voicePanelClearLast, role: .destructive) {
                    clearLastSegment()
                }
                .disabled(!transcript.canClearLast || model?.hasPendingTranscriptions == true)
                Button(L10n.voicePanelClearAll, role: .destructive) {
                    clearAllSegments()
                }
                Button(L10n.commonCancel, role: .cancel) {}
            }
            .voiceConfirmSheet($confirmSet, route: routeMonitor.route,
                               judgedTarget: judgedIntent,
                               judgedConfidence: judgedConfidence,
                               onJudgedTargetChange: { newKey in
                guard !isSaving, let source = confirmationSource,
                      confirmationPatientID == app.currentPatientId,
                      transcript.matches(source, authorized: refinerEnabled,
                                         authorizationGeneration: settings.authAIRevision) else { return }
                understandingTask?.cancel()
                judgedIntent = newKey
                judgedConfidence = 0.9
                let key = VoiceIntentKey(rawValue: newKey) ?? .unknown
                let drafts = VoiceIntentCatalog.extract(for: key, text: source.selectedText,
                                                        confidence: lastTranscript?.confidence ?? 0.9)
                // A new confirmation identity rejects callbacks from the previous target's sheet.
                confirmSet = VoiceInputTemplate.confirmationSet(drafts: drafts)
            }) { confirmed in
                startDispatch(confirmed)
            }
            .interactiveDismissDisabled(isSaving)
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

    /// 转写模型装配（@Environment 不可用于 @State 初始值，同
    /// VoiceDictationButton 纪律）：每次渲染刷新闭包——父视图重渲染传入
    /// 捕获最新 @State 的新闭包，模型持有的旧闭包会使确认/分发按旧状态
    /// 执行；BR-012 前置在模型内统一执行（命中即收起全屏跳急救卡）
    private func ensureModel() {
        // VoiceQuickLaunchView 为 struct：值语义捕获 self 即可（@State 经
        // 属性包装器存储引用共享），weak 仅适用于 class——L1 34300325273 族
        let m = model ?? VoiceDictationModel(engine: app.transcriptionEngine)
        m.onTranscript = { text, confidence in
            self.appendSegment(text, confidence: confidence)
        }
        m.onEmergency = { _ in
            self.dismiss()
            self.router.navigate(to: .emergencyCardConfig)
        }
        // FR17.15 V3.61：主语言 = 保序首位；混说开关真消费（词表注入 contextualStrings）
        m.applyLanguageSettings(storedLocales: settings.values[.voiceInputLanguages],
                                mixedInput: settings.values[.voiceMixedInput] != "false",
                                recentDrugNames: hub.inventoryItems.map(\.medicationName))
        if model == nil { model = m }
    }

    private func invalidateConfirmation() {
        understandingTask?.cancel()
        understandingTask = nil
        isUnderstanding = false
        confirmSet = nil
        confirmationSource = nil
        confirmationPatientID = nil
        judgedIntent = nil
        judgedConfidence = 0
        failedDispatch = nil
        showSaveFailure = false
    }

    private func stopRefinement() {
        refinementTask?.cancel()
        refinementTask = nil
        transcript.cancelRefinement()
    }

    private func revokeRefinement() {
        stopRefinement()
        transcript.revokeAI()
        if let source = confirmationSource,
           !transcript.matches(source, authorized: refinerEnabled, authorizationGeneration: settings.authAIRevision) {
            invalidateConfirmation()
        }
    }

    private func selectVersion(_ version: TranscriptVersion) {
        guard !isSaving, version != transcriptVersion else { return }
        stopRefinement()
        invalidateConfirmation()
        transcript.select(version, authorized: refinerEnabled)
        if transcriptVersion == .refined { refineCurrentText() }
    }

    private func editTranscript(_ text: String) {
        guard !accumulatedText.utf8.elementsEqual(text.utf8) else { return }
        stopRefinement()
        invalidateConfirmation()
        transcript.edit(text)
        lastTranscript = nil
        if transcriptVersion == .refined { refineCurrentText() }
    }

    /// Append history marks exact source byte boundaries, never newline-derived stale copies.
    private func appendSegment(_ text: String, confidence: Double) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        stopRefinement()
        invalidateConfirmation()
        lastTranscript = (text, confidence)
        transcript.append(text)
        if transcriptVersion == .refined { refineCurrentText() }
    }

    /// 清除最近一次录音（1.2 默认选项）
    private func clearLastSegment() {
        guard !isSaving, transcript.canClearLast, model?.hasPendingTranscriptions != true else { return }
        stopRefinement()
        invalidateConfirmation()
        transcript.clearLast()
        if transcriptVersion == .refined { refineCurrentText() }
    }

    /// 清除全部录音（1.2）：工作台归零
    private func clearAllSegments() {
        guard !isSaving else { return }
        model?.stopForDisappear()
        stopRefinement()
        invalidateConfirmation()
        transcript.clearAll()
        lastTranscript = nil
    }

    /// Freeze one selected source; confirming native text never awaits inference.
    private func confirmFromTranscript() {
        guard !isSaving, !isUnderstanding, model?.hasPendingTranscriptions != true else { return }
        stopRefinement()
        if sourceSnapshot.version == .native {
            transcript.select(.native, authorized: refinerEnabled)
        }
        let source = sourceSnapshot
        guard !source.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              transcript.canCommit(source, authorized: refinerEnabled, authorizationGeneration: settings.authAIRevision,
                                   preservesOriginal: false) else { return }
        if EmergencyKeywordRules.match(source.nativeText) || EmergencyKeywordRules.match(source.selectedText) {
            dismiss()
            router.navigate(to: .emergencyCardConfig)
            return
        }
        invalidateConfirmation()
        let patientID = app.currentPatientId
        confirmationSource = source
        confirmationPatientID = patientID
        isUnderstanding = true
        let confidence = lastTranscript?.confidence ?? 0.9
        understandingTask = Task {
            await understand(source: source, confidence: confidence, patientID: patientID)
            guard !Task.isCancelled, confirmationSource == source else { return }
            isUnderstanding = false
            understandingTask = nil
        }
    }

    private func refineCurrentText() {
        guard !isSaving, !isUnderstanding else { return }
        stopRefinement()
        guard let request = transcript.beginRefinement(authorized: refinerEnabled,
                                                       authorizationGeneration: settings.authAIRevision) else { return }
        invalidateConfirmation()
        let locale = model?.resolvedLocale ?? model?.preferredLocale ?? TranscriptionSegmentation.fallbackLocale
        let drugNames = hub.inventoryItems.map(\.medicationName)
        refinementTask = Task {
            guard !Task.isCancelled, refinerEnabled,
                  request.generation == transcript.generation,
                  request.authorizationGeneration == settings.authAIRevision else {
                if request.generation == transcript.generation {
                    transcript.revokeAI()
                    refinementTask = nil
                }
                return
            }
            let result = await app.textRefiner.refine(request.nativeText, localeIdentifier: locale, drugNames: drugNames)
            guard !Task.isCancelled, request.generation == transcript.generation else { return }
            transcript.publish(result, for: request, authorized: refinerEnabled,
                               authorizationGeneration: settings.authAIRevision)
            refinementTask = nil
        }
    }

    /// 共享文本理解层自动判定（FR17.18 期一：兜底轨文法/启发式）——
    /// 单次调用产出意图 + 槽位草稿，替代此前三套正则并行抽取的内联实现。
    /// 转写置信度随输入传递（此前在此处被丢弃、引擎恒按 0.9 分类）
    private func understand(source: TranscriptSourceSnapshot, confidence: Double, patientID: UUID) async {
        guard !Task.isCancelled, patientID == app.currentPatientId, confirmationSource == source,
              transcript.matches(source, authorized: refinerEnabled,
                                 authorizationGeneration: settings.authAIRevision) else { return }
        let understanding = EngineRegistry.shared.resolve(TextUnderstandingFactory.self)
        let result = await understanding.understand(
            TextUnderstandingInput(text: source.selectedText,
                                   source: .voice(intentHint: nil, confidence: confidence)))
        guard !Task.isCancelled, patientID == app.currentPatientId, confirmationSource == source,
              transcript.matches(source, authorized: refinerEnabled,
                                 authorizationGeneration: settings.authAIRevision) else { return }
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

    private func startDispatch(_ set: OcrConfirmationSet) {
        guard !isSaving, let source = confirmationSource, let patientID = confirmationPatientID,
              patientID == app.currentPatientId,
              set.documentId == confirmSet?.documentId || set.documentId == failedDispatch?.documentId,
              transcript.canCommit(source, authorized: refinerEnabled, authorizationGeneration: settings.authAIRevision,
                                   preservesOriginal: false) else { return }
        let intent = judgedIntent
        isSaving = true
        showSaveFailure = false
        confirmSet = nil
        Task { await dispatch(set, source: source, patientID: patientID, intent: intent) }
    }

    private func retryDispatch() {
        if let failedDispatch, let source = confirmationSource, confirmationPatientID == app.currentPatientId,
           transcript.canCommit(source, authorized: refinerEnabled, authorizationGeneration: settings.authAIRevision,
                                preservesOriginal: false) {
            startDispatch(failedDispatch)
        } else {
            confirmFromTranscript()
        }
    }

    /// Persist before clearing. A vacant router slot acknowledges handoff, not target-page persistence.
    private func dispatch(_ set: OcrConfirmationSet, source: TranscriptSourceSnapshot,
                          patientID: UUID, intent: String?) async {
        defer { isSaving = false }
        guard patientID == app.currentPatientId,
              transcript.canCommit(source, authorized: refinerEnabled, authorizationGeneration: settings.authAIRevision,
                                   preservesOriginal: false) else { return }
        let fields = set.confirmedFields
        let target = target(for: intent)
        switch target {
        case .anyText, .observation, .question, .ai:
            guard let body = fields.first?.value, !body.isEmpty else {
                failedDispatch = set
                showSaveFailure = true
                return
            }
            let succeeded = await voiceNoteState.create(patientId: patientID, body: body, tags: nil)
            guard succeeded else {
                failedDispatch = set
                showSaveFailure = true
                return
            }
        case .metric, .reminder, .profile:
            guard !fields.isEmpty, router.pendingVoiceIntent == nil else {
                failedDispatch = set
                showSaveFailure = true
                return
            }
            router.pendingVoiceIntent = set.pendingIntent(intent ?? VoiceIntentKey.unknown.rawValue)
        }
        guard patientID == app.currentPatientId,
              transcript.finishCommit(source, authorized: refinerEnabled, authorizationGeneration: settings.authAIRevision,
                                      succeeded: true) else { return }
        invalidateConfirmation()
        lastTranscript = nil
        if target == .anyText {
            savedNote = true
        } else {
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
