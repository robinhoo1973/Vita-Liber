import SwiftUI
import Domain
import Protocols

/// FR8.9 / FR17.1 端上听写状态机（原 VoiceDictationButton.swift）：
/// SFSpeechRecognizer（`requiresOnDeviceRecognition=true`，offline-first）
/// 听写 → 实时部分文本 → 完成回调（调用方走 FR17.13 统一确认模板）。
///
/// 2026-09-09 死代码清除：`VoiceDictationButton` 视图随 §4.23 中部大号
/// 按住说话按钮（PressToTalkMicButton）落地而零实例化——视图结构删除，
/// 本文件只保留模型与节流门（新组件依赖）。BR-012 前置在模型内统一执行
/// （命中即跳过草稿投递并调用 onEmergency）。
///
/// 并发纪律（评审修正）：引擎的 `onPartial` 是 **@Sendable 非隔离**回调，
/// 若在其中捕获视图 `@State`（非 Sendable）会在 Swift 6 严格并发下编译
/// 失败——录音/部分文本/失败态下沉到本模型（@MainActor @Observable，
/// 即 Sendable），回调只捕获 model 并按 MainActor 投递。

/// 单次听写的状态机（@MainActor @Observable = Sendable）：可被 @Sendable 回调安全捕获。
@MainActor
@Observable
final class VoiceDictationModel {
    enum Phase: Equatable { case idle, recording, failed }
    private(set) var phase: Phase = .idle
    /// 连续会话显示文本 = 已提交段 + 当前部分（引擎 onPartial 已合并，V3.61）
    private(set) var partial = ""
    /// 最近一次实际识别 locale（FR17.15 能力诚实：方言回落主语言时面板回显）
    private(set) var resolvedLocale: String?
    var onTranscript: ((String, Double) -> Void)?
    /// BR-012 紧急关键词横切动作（命中即调用并跳过 onTranscript 草稿投递）
    var onEmergency: ((String) -> Void)?

    private let engine: any TranscriptionEngine
    // 视图在每次渲染时按最新设置更新（FR14.7 即时生效），故 setter 为 internal——
    // 与 phase/partial 的 private(set) 不同（第九轮 M1.5 审查：stale 闭包修复）
    var preferredLocale: String?
    /// FR17.15 混说词表（主语言 + 混说开关 + 已确认药名 → contextualStrings；空 = 不注入）
    var contextualStrings: [String] = []
    private var task: Task<Void, Never>?
    private var stopped = false
    /// 会话代次：start 递增。收尾期（stop 后引擎仍在等静音端点）旧会话的
    /// 结果/部分文本按代次丢弃，防「快速重录时旧引擎文本污染新会话」。
    private var session = 0
    /// 每会话独立的节流门（审查修复：此前为全局单例，两个同时在途的听写
    /// 会话共享 lastText——A 先吐出的文本会把 B 的相同部分结果压掉，
    /// 「每次会话独立节流状态」的语义落空；reset 也会互相踩）。
    private let partialGate = PartialGate()

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
        guard let resolvedLocale, let preferredLocale else { return false }
        return resolvedLocale != preferredLocale
    }

    func start() {
        // 重入守卫：.disabled 只是渲染态，快速双击的第二次点击在重渲染前仍会进来
        guard phase != .recording else { return }
        session += 1
        phase = .recording
        partial = ""
        stopped = false
        partialGate.reset()   // 每次会话独立节流状态（跨会话文本不互相吞）
        task = Task { [session] in await dictate(session: session) }
    }

    /// 用户收尾（松手/点按停止，FR17.1）：立即回 idle 可重录，但不取消
    /// 引擎——SFSpeechRecognizer 在静音端点后给出 isFinal 最终文本，在途
    /// 转写必须投递（二轮审查：此前 stop 即取消，`guard !stopped` 把松手后
    /// 的全文静默丢弃，速记/指标/提醒草稿从不落编辑区）。引擎侧无外部取消
    /// （已登记待办），收尾由会话代次守卫界定归属。
    func stop() {
        guard phase == .recording else { return }
        phase = .idle
        // 软停提示：旧引擎尽快 endAudio 收尾（不取消——在途转写保留投递，
        // 由会话代次守卫界定归属）；避免旧会话与新录音竞争共享音频会话
        Task { await self.engine.endAudio() }
    }

    /// 视图销毁硬停：取消在途会话、不再投递（引擎仍由 isFinal 自然收尾，
    /// 到达后按 stopped 守卫丢弃——与既有取消路径行为一致）。
    func stopForDisappear() {
        stopped = true
        task?.cancel()
        // 终止会话即回 idle——phase 滞留 .recording 时 start() 被重入守卫
        // 拦下，听写死掉直到视图身份重建（TabView 切走再切回场景）。
        phase = .idle
    }

    private func dictate(session: Int) async {
        let engine = self.engine
        // FR17.15：方言不可用时引擎内回落（SFSpeechTranscriber 已映射）；
        // 这里只补「无可用 locale 探测结果」的末级兜底——单一口径 TranscriptionSegmentation.fallbackLocale。
        let locale = preferredLocale
            ?? engine.capability.availableLocales.first
            ?? TranscriptionSegmentation.fallbackLocale
        let gate = partialGate
        do {
            let result = try await engine.transcribe(
                TranscriptionRequest(localeIdentifier: locale, contextualStrings: contextualStrings),
                onPartial: { [weak self] text in
                    // @Sendable 非隔离回调：只捕获 model（MainActor 类 = Sendable）
                    // 与会话门（局部拷贝，非隔离可安全捕获），去重后按 MainActor 投递。
                    gate.pass(text) { latest in
                        Task { @MainActor in self?.applyPartial(latest, session: session) }
                    }
                })
            // V3.61：连续会话下 isFinal 只在松手后到达一次——旧会话的最终文本是用户
            // 说过的话，**不再因快速重按换代而丢弃**（此前整段丢失）；只有视图级硬停
            //（stopped）才不投递。换代时不改新会话的 phase/partial。
            guard !stopped else { return }
            let isCurrent = self.session == session
            resolvedLocale = result.resolvedLocale
            if !result.text.trimmingCharacters(in: .whitespaces).isEmpty {
                if isCurrent { phase = .idle }
                // BR-012 紧急关键词前置（V3.40 横切义务）：判定在本组件内统一
                // 执行——此前仅快速面板与 F19 键盘路径实现，其余 6 处入口
                // 听写文本直入确认草稿，「我胸闷」被存成观察/速记而非急救卡
                // （红线一票否决）。命中即跳急救卡配置页并跳过草稿投递。
                if EmergencyKeywordRules.match(result.text), let onEmergency {
                    onEmergency(result.text)
                    return
                }
                onTranscript?(result.text, result.confidence)
            } else if isCurrent {
                phase = .failed   // FR8.9：识别失败静默降级为手输并给输入框轻提示
            }
        } catch is CancellationError {
            return   // 硬停/视图级取消：非失败
        } catch {
            guard !stopped, self.session == session else { return }
            phase = .failed
        }
    }

    private func applyPartial(_ text: String, session: Int) {
        guard phase == .recording, self.session == session else { return }   // 视图不在录音态或会话已换代则不投递
        partial = text
    }
}

/// 部分结果节流门：SFSpeechRecognizer 每秒数次回调，文本未变即跳过——
/// 避免高频 Task 分配与重复渲染；文本变化立即放行（不引入丢尾部风险）。
/// 每次会话 start 时 reset；实例归单个 VoiceDictationModel 所有，
/// 跨会话/跨屏不串扰（并发会话不共享节流状态）。
private final class PartialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastText = ""

    func pass(_ text: String, deliver: (String) -> Void) {
        lock.lock()
        let changed = text != lastText
        if changed { lastText = text }
        lock.unlock()
        if changed { deliver(text) }
    }

    func reset() {
        lock.lock()
        lastText = ""
        lock.unlock()
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

    @State private var model: VoiceDictationModel?
    /// 长按手势按下起点（用于判定「真长按」vs 快速点按）
    @State private var pressBeganAt: Date?

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
                    Button {
                        // §5.54「按住说话」的触屏等价（点按切换）：录音中再按
                        // 即停止——此前录音态按钮被 disabled，引擎未自动收尾时
                        // 麦克风只能等视图销毁才停（隐私/UX 死胡同，无障碍不可达）。
                        // 长按即录/松手即停由下方 onLongPressGesture 承担（FR17.1）；
                        // 两种停录都走 stop() 软收尾，在途转写保留投递。
                        if model.phase == .recording {
                            model.stop()
                        } else {
                            model.start()
                        }
                    } label: {
                        Label(model.phase == .recording ? L10n.voicenoteStop : L10n.voicenoteDictation,
                              systemImage: model.phase == .recording ? "stop.circle" : "mic")
                            .frame(maxWidth: .infinity, minHeight: 44)   // 触控目标 ≥44pt（ui-ux §4.2）
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("voice.dictation.start")
                    // FR17.1「按住说话」实装（审查修复）：此前全 App 零长按
                    // 录音入口（grep 仅 SOS 按住确认在用 LongPress）。长按
                    // ≥0.2s 即开始录音（perform 内开录）、松手即停；长按被
                    // 手势识别后 Button 点按动作不再触发（手势优先），快速
                    // 点按完全走上方切换逻辑。
                    // 状态纪律（二轮审查修复）：开录不得放 pressing(true)——
                    // 该回调在手指落下的瞬间触发，早于 0.2s 判定，会把快速
                    // 点按也拖进「开录→松手停录」；随后 Button 动作看到的是
                    // 已被按停的 idle 态，点按切换被反转（录音中点按停不了、
                    // 空闲点按触发 start→stop→start 三次引擎翻动）。pressBeganAt
                    // 只在松手侧按持有时长判定是否真长按，点按路径零干预。
                    .onLongPressGesture(minimumDuration: 0.2, pressing: { pressing in
                        if pressing {
                            pressBeganAt = Date()
                        } else {
                            let heldLong = pressBeganAt.map { Date().timeIntervalSince($0) >= 0.2 } ?? false
                            pressBeganAt = nil
                            if heldLong && model.phase == .recording {
                                model.stop()
                            }
                        }
                    }, perform: {
                        model.start()   // 长按成立（≥0.2s）才开录——快速点按不经过此路径
                    })
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
                }
                .onDisappear { model.stopForDisappear() }   // 视图销毁即终止在途听写投递（引擎无内部取消）
            }
        }
        // 引擎在环境就绪后装配一次（@Environment 不可用于 @State 初始值）；
        // task(id:) 挂语音语言存储值——面板内改语言返回后 .task 不重跑、
        // preferredLocale 停留旧值（FR17.15 即时生效落空），值一变即重建
        .task(id: "\(settings.values[.voiceInputLanguages] ?? "")|\(settings.values[.voiceMixedInput] ?? "")") { ensureModel() }
    }

    /// 引擎在环境就绪后装配（@Environment 不可用于 @State 初始值）。
    /// 审查修复：每次调用都刷新 `onTranscript`——SwiftUI 父视图每次重渲染
    /// 都会传入捕获最新 @State 的新闭包；此前只装配一次，模型持有首帧的
    /// 旧闭包，用户在面板出现后点的目标 chip（userPickedTarget）对听写
    /// 回调不可见，确认/分发按旧状态执行（FR17.9 显式覆盖失效）。
    private func ensureModel() {
        // FR17.15 审查修复：用户选择的输入语言必须生效——此前识别 locale 只由
        // 引擎能力探测决定，设置页多选「可调但无效果」（FR14.7 V3.26 违例）。
        // 单一选择 = 该语言；多选 = 取第一个（引擎内再按能力回落）。
        // 解析规则收敛 Domain SettingsRules（与设置页存储格式同源）。
        let m = model ?? VoiceDictationModel(engine: app.transcriptionEngine)
        m.onTranscript = onTranscript
        m.onEmergency = onEmergency
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
