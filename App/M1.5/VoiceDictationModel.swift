import SwiftUI
import Domain
import Protocols

/// FR17.1: press identity, capture lifetime, and ordered final delivery are separate concerns.
@MainActor
@Observable
final class VoiceDictationModel {
    enum Phase: Equatable { case idle, recording, failed }
    private(set) var phase: Phase = .idle
    /// 连续会话显示文本 = 已提交段 + 当前部分（引擎 onPartial 已合并，V3.61）
    private(set) var partial = ""
    /// 最近一次实际识别 locale（FR17.15 能力诚实：方言回落主语言时面板回显）
    private(set) var resolvedLocale: String?
    private(set) var hasIncompleteTranscript = false
    var hasPendingTranscriptions: Bool { !contexts.isEmpty }
    var onTranscript: ((String, Double) -> Void)?
    /// BR-012 紧急关键词横切动作（命中即调用并跳过 onTranscript 草稿投递）
    var onEmergency: ((String) -> Void)?
    /// Synchronous activity notifications keep guided controls correct before the next SwiftUI render.
    var onActivityChange: ((Bool) -> Void)?

    private let engine: any TranscriptionEngine
    var preferredLocale: String?
    /// FR17.15 混说词表（主语言 + 混说开关 + 已确认药名 → contextualStrings；空 = 不注入）
    var contextualStrings: [String] = []
    private struct PressContext {
        let request: TranscriptionRequest
        let epoch: UInt64
        let onTranscript: ((String, Double) -> Void)?
        let onEmergency: ((String) -> Void)?
        let partialGate = PartialGate()
    }

    private var authorized = true
    private var epoch: UInt64 = 0
    private var currentID: UUID?
    private var recordingID: UUID?
    private var displayRequestedLocale: String?
    private var partialRevision: UInt64 = 0
    private var contexts: [UUID: PressContext] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var deliveryOrder: [UUID] = []
    private var completed: [UUID: Result<TranscriptionResult, Error>] = [:]
    /// A new press waits only for preceding capture shutdown, never for its final transcript.
    private var controlTask: Task<Void, Never>?

    init(engine: any TranscriptionEngine, preferredLocale: String? = nil) {
        self.engine = engine
        self.preferredLocale = preferredLocale
    }

    /// FR17.15 V3.61：按设置装配主语言与混说词表（设置页保序：首位 = 主语言；
    /// 混说开关关 = 不注入词表；已确认药名来自药箱库存摘要）
    func applyLanguageSettings(storedLocales: String?, mixedInput: Bool, recentDrugNames: [String]) {
        let locales = SettingsRules.voiceLocales(storedLocales)
        preferredLocale = locales.first
        contextualStrings = mixedInput
            ? MixedSpeechVocabulary.terms(primaryLocale: locales.first ?? TranscriptionSegmentation.fallbackLocale,
                                          otherLocales: Array(locales.dropFirst()),
                                          recentDrugNames: recentDrugNames)
            : []
    }

    /// FR17.15 能力诚实：实际识别 locale 与主语言不同 = 方言回落（尽力识别）
    var isBestEffortFallback: Bool {
        guard let resolvedLocale, let displayRequestedLocale else { return false }
        return TranscriptionLocale.normalizedIdentifier(resolvedLocale)
            != TranscriptionLocale.normalizedIdentifier(displayRequestedLocale)
    }

    func start() {
        guard authorized, phase != .recording else { return }
        let request = TranscriptionRequest(localeIdentifier: preferredLocale ?? TranscriptionSegmentation.fallbackLocale,
                                           contextualStrings: contextualStrings)
        let context = PressContext(request: request, epoch: epoch,
                                   onTranscript: onTranscript, onEmergency: onEmergency)
        currentID = request.sessionID
        recordingID = request.sessionID
        displayRequestedLocale = request.localeIdentifier
        phase = .recording
        partial = ""
        partialRevision = 0
        resolvedLocale = nil
        hasIncompleteTranscript = false
        contexts[request.sessionID] = context
        deliveryOrder.append(request.sessionID)
        let precedingControl = controlTask
        tasks[request.sessionID] = Task { [weak self] in
            await precedingControl?.value
            await self?.dictate(context)
        }
        if contexts.count == 1 { onActivityChange?(true) }
    }

    /// Release stops the identified capture; its final result remains deliverable.
    func stop() {
        guard let id = recordingID else { return }
        recordingID = nil
        phase = .idle
        let precedingControl = controlTask
        let engine = engine
        controlTask = Task {
            await precedingControl?.value
            await engine.finish(sessionID: id)
        }
    }

    func stopForDisappear() {
        epoch &+= 1
        let ids = deliveryOrder
        let oldTasks = Array(tasks.values)
        contexts.removeAll()
        tasks.removeAll()
        completed.removeAll()
        deliveryOrder.removeAll()
        currentID = nil
        recordingID = nil
        phase = .idle
        partial = ""
        resolvedLocale = nil
        hasIncompleteTranscript = false
        oldTasks.forEach { $0.cancel() }
        guard !ids.isEmpty else {
            onActivityChange?(false)
            return
        }
        let precedingControl = controlTask
        let engine = engine
        controlTask = Task {
            await precedingControl?.value
            for id in ids {
                await engine.cancel(sessionID: id)
                await engine.discardSession(sessionID: id)
            }
        }
        onActivityChange?(false)
    }

    func setAuthorization(_ allowed: Bool) {
        guard authorized != allowed else { return }
        authorized = allowed
        if !allowed { stopForDisappear() }
    }

    private func dictate(_ context: PressContext) async {
        let id = context.request.sessionID
        let lifetime = context.epoch
        guard lifetime == epoch, contexts[id] != nil, !Task.isCancelled else { return }
        let gate = context.partialGate
        let outcome: Result<TranscriptionResult, Error>
        do {
            let capability = await engine.currentCapability()
            try Task.checkCancellation()
            guard lifetime == epoch, contexts[id] != nil else { return }
            if currentID == id { resolvedLocale = capability.resolvedLocale(for: context.request.localeIdentifier) }
            let result = try await engine.transcribe(context.request, onPartial: { [weak self] text in
                guard let revision = gate.accept(text) else { return }
                Task { @MainActor [weak self] in
                    self?.applyPartial(text, revision: revision, sessionID: id, epoch: lifetime)
                }
            })
            try Task.checkCancellation()
            outcome = .success(result)
        } catch {
            outcome = .failure(error)
        }
        guard lifetime == epoch, contexts[id] != nil else { return }
        tasks[id] = nil
        completed[id] = outcome
        if currentID == id {
            recordingID = nil
            switch outcome {
            case .success(let result):
                resolvedLocale = result.resolvedLocale.isEmpty ? nil : result.resolvedLocale
                hasIncompleteTranscript = result.completion != .final
                phase = result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .failed : .idle
            case .failure(let error):
                resolvedLocale = nil
                phase = error is CancellationError ? .idle : .failed
            }
        }
        while let next = deliveryOrder.first, let result = completed.removeValue(forKey: next) {
            deliveryOrder.removeFirst()
            guard let original = contexts.removeValue(forKey: next) else { continue }
            if case .success(let transcript) = result,
               !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if EmergencyKeywordRules.match(transcript.text) {
                    original.onEmergency?(transcript.text)
                } else {
                    original.onTranscript?(transcript.text, transcript.completion == .final ? transcript.confidence : 0)
                }
            }
            // A consumer may synchronously dismiss/revoke while processing a result.
            if lifetime != epoch { break }
        }
        if lifetime == epoch, contexts.isEmpty { onActivityChange?(false) }
    }

    private func applyPartial(_ text: String, revision: UInt64, sessionID: UUID, epoch: UInt64) {
        guard self.epoch == epoch, recordingID == sessionID, phase == .recording,
              revision > partialRevision else { return }
        partialRevision = revision
        partial = text
    }
}

/// Per-press deduplication and revisions protect asynchronous MainActor delivery order.
private final class PartialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastText = ""
    private var revision: UInt64 = 0

    func accept(_ text: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard text != lastText else { return nil }
        lastText = text
        revision &+= 1
        return revision
    }
}
///
/// 识别失败静默降级（FR8.9）：轻提示「可继续手动输入」，绝不阻断手输路径；
/// 音频零落盘由 TranscriptionEngine 类型级保证（FR17.7），本视图只接触文本。
///
/// 并发纪律（评审修正，CI 编译红自查）：引擎的 `onPartial` 是 **@Sendable 非隔离**回调，
/// 若在其中捕获视图 `@State`（非 Sendable 的 State wrapper）会在 Swift 6 严格并发下
/// 编译失败——录音/部分文本/失败态下沉到 `VoiceDictationModel`（@MainActor @Observable，
/// 即 Sendable），回调只捕获 model 并按 MainActor 投递。
@MainActor
struct VoiceDictationButton: View {
    @Environment(AppState.self) private var app
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(M2HubStore.self) private var hub
    /// 完成回调：文本 + 引擎置信度（落 C 级草稿、低置信强制复核由 FR17.13 模板承担）
    let onTranscript: (String, Double) -> Void
    /// BR-012 横切动作注入（默认仅跳急救卡配置页；承载于 sheet/
    /// fullScreenCover 的调用方必须注入「先收起再跳转」——否则急救卡
    /// 被未关闭的面板盖住，用户在面板内看不到任何变化）
    var onEmergencyAction: ((String) -> Void)? = nil
    var isBusy: Binding<Bool>? = nil

    @State private var model: VoiceDictationModel?

    var body: some View {
        Group {
            // FR14.1 authVoiceDictation 消费点：关闭 → 禁用态回落手输
            // （FR8.9 降级语义：识别失败/未授权均静默降级为手输 + 轻提示）
            if settings.values[.authVoiceDictation] == "false" {
                Label(L10n.privacyAuthVoiceDisabled, systemImage: "mic.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("voice.dictation.authDisabled")
            } else if let model {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.phase == .recording ? L10n.voicenoteStop : L10n.voicenoteDictation,
                          systemImage: model.phase == .recording ? "stop.circle" : "mic")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, 12)
                        .foregroundStyle(.white)
                        .background(Color("brand-primary", bundle: .main), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("voice.dictation.start")
                        .modifier(DictationInteraction(model: model))
                    if model.phase == .recording && !model.partial.isEmpty {
                        Text(model.partial)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .accessibilityIdentifier("voice.dictation.partial")
                    }
                    if model.phase == .failed {
                        Text(L10n.voicenoteDictationFailed)
                            .font(.caption)
                            .foregroundStyle(Color("semantic-warning", bundle: .main))
                    }
                    if model.hasIncompleteTranscript {
                        Label(L10n.voiceLangT2Point3, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Color("semantic-warning", bundle: .main))
                    }
                    if let locale = model.resolvedLocale {
                        Text(L10n.voiceRecognizedAs(locale))
                            .font(.caption2).foregroundStyle(.secondary)
                        if model.isBestEffortFallback {
                            Text(L10n.voiceLangBestEffort).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        // 引擎在环境就绪后装配一次（@Environment 不可用于 @State 初始值）；
        // task(id:) 挂语音语言存储值——面板内改语言返回后 .task 不重跑、
        // preferredLocale 停留旧值（FR17.15 即时生效落空），值一变即重建
        .task(id: "\(settings.values[.voiceInputLanguages] ?? "")|\(settings.values[.voiceMixedInput] ?? "")") { ensureModel() }
        .onChange(of: settings.values[.authVoiceDictation]) { _, value in
            model?.setAuthorization(value != "false")
        }
    }

    /// Each press snapshots these inputs. Guided field changes create a new button identity.
    private func ensureModel() {
        // FR17.15 审查修复：用户选择的输入语言必须生效——此前识别 locale 只由
        // 引擎能力探测决定，设置页多选「可调但无效果」（FR14.7 V3.26 违例）。
        // 单一选择 = 该语言；多选 = 取第一个（引擎内再按能力回落）。
        // 解析规则收敛 Domain SettingsRules（与设置页存储格式同源）。
        let m = model ?? VoiceDictationModel(engine: app.transcriptionEngine)
        m.setAuthorization(settings.values[.authVoiceDictation] != "false")
        m.onTranscript = onTranscript
        m.onEmergency = onEmergency
        let busyBinding = isBusy
        m.onActivityChange = { busyBinding?.wrappedValue = $0 }
        busyBinding?.wrappedValue = m.hasPendingTranscriptions
        // FR17.15 V3.61：主语言 = 保序首位；混说开关真消费（词表注入 contextualStrings）
        m.applyLanguageSettings(storedLocales: settings.values[.voiceInputLanguages],
                                mixedInput: settings.values[.voiceMixedInput] != "false",
                                recentDrugNames: hub.inventoryItems.map(\.medicationName))
        if model == nil { model = m }
    }

    /// BR-012 紧急关键词命中时的横切动作（组件内统一前置——此前仅快速面板
    /// 与 F19 键盘路径实现，其余入口「我胸闷」被存成观察/速记而非急救卡）
    private var onEmergency: ((String) -> Void)? {
        onEmergencyAction ?? { _ in router.navigate(to: .emergencyCardConfig) }
    }
}
