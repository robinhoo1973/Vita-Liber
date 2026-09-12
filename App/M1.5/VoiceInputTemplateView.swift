import SwiftUI
import AVFoundation
import Domain
import Protocols

/// **FR17.13 标准语音输入模板（唯一实现）**
///
/// 语音指导每步（FR17.11）/ 语音速记（FR17.9）/ 语音提醒设定（FR17.10）/
/// 观察语音速记（FR8.9）四处确认**一律**复用本文件的 `VoiceConfirmSheet`，
/// 禁止各功能自建独立确认逻辑。L0 门禁 [9/9] 对此做静态断言：
/// 四处入口须各有 `// FR17.13-entry:` 标记且调用 `VoiceInputTemplate.confirmationSet`；
/// 同时 `OcrConfirmationSet` 只允许在 Domain 内构造，App 层无法自行拼装确认集。
///
/// 决策半场在 Domain（`ReadbackPolicy`）——本文件只负责把决策渲染成界面，
/// 不含任何业务判断（tech-spec §1.1 规则 4）。

// MARK: - 音频路由监听（耳机感知）

/// FR17.13：探测输出路由，并在录入过程中拔/插耳机时**即时**切换回读策略。
/// 路由切换的轻提示（Toast）由 VoiceConfirmSheet 自行呈现（其观察自身
/// decision/route 变化——此前本监视器的 routeChangeToast 只写不读、Toast
/// 从未上屏，属死状态，已随审查清理）。
@MainActor
@Observable
final class AudioRouteMonitor {
    private(set) var route: AudioRoute = .speaker

    private var observer: NSObjectProtocol?

    init() { refresh() }

    func start() {
        refresh()
        // 审查修复（观察者泄漏）：start() 此前非幂等——每次调用无条件
        // addObserver 覆盖旧 token，先前注册的 NotificationCenter 块被
        // 中心永久持有直至进程结束（stop() 只能移除最后一次注册的）。
        // 幂等守卫：已注册则直接返回（与 VoiceLevelMeter.started 同款）。
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func refresh() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let headphonePorts: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio,
        ]
        route = outputs.contains { headphonePorts.contains($0.portType) } ? .headphones : .speaker
    }
}

// MARK: - 统一确认卡（四处入口共用）

/// 语音草稿确认卡。**唯一**的语音确认 UI。
struct VoiceConfirmSheet: View {
    let set: OcrConfirmationSet
    let decision: ReadbackDecision
    /// 输出路由（耳机感知）：随宿主视图重渲染更新——onChange(of:) 驱动
    /// FR17.13「输入过程中拔/插耳机即时切换回读策略」。
    let route: AudioRoute
    /// V3.49 判定结果行（4.27 可选元素，FR17.9 去 chips 后去向的唯一呈现）：
    /// 意图 key（nil=无法判定，改渲染候选去向行）；置信度 <0.5 视为低置信。
    var judgedTarget: String?
    var judgedConfidence: Double
    /// Menu/候选行改类回调（面板重抽槽位后替换确认集）
    var onJudgedTargetChange: ((String) -> Void)?
    /// 点 [🔊 朗读] 或自动回读时调用（TTS 由调用方注入，便于测试替身）
    var onSpeak: ((String) -> Void)?
    /// FR17.13 拔耳机中断回读：路由从耳机切走时调用（TTS 由调用方停止）
    var onStopSpeak: (() -> Void)?
    var onConfirm: (OcrConfirmationSet) -> Void
    var onRetry: () -> Void
    var onCancel: () -> Void

    @State private var askAnswered = false
    @State private var didAutoSpeak = false
    /// 路由切换轻提示（FR17.13「切换时给轻提示（Toast）」——此前
    /// AudioRouteMonitor.routeChangeToast 只写不读，Toast 从未上屏）
    @State private var routeToast: String?
    @State private var routeToastTask: Task<Void, Never>?
    /// TestFlight 实测修复：字段可编辑——未识别/识别错的字段由用户在卡上直接补全
    @State private var edits: [UUID: String] = [:]

    /// 回读脚本 = 已确认字段（BR-003：未确认内容不得被当作事实播报）。
    /// 确认卡呈现时字段尚未确认，故按「即将保存的取值」构造预览脚本：
    /// 与保存按钮走**同一个** applyingEdits 变换（审查修复：此前脚本用
    /// 未编辑原值、保存用编辑后值——用户在卡上改完字段再点 [朗读]，
    /// 听到的与最终落库的不一致，无障碍用户听到从未被记录的数值）。
    private var script: String? {
        // 审查修复（V3.68 §11 清偿残根）：句式经 L10n.voiceReadbackFmt 组装、
        // 字段名经 label(for:) 本地化映射——原 Domain readbackScript 直拼
        // displayLabel（语音路径下是英文内部键），TTS 把 "blood_pressure_sys"
        // 原样念给用户听。
        guard let parts = ReadbackPolicy.readbackParts(applyingEdits()) else { return nil }
        let body = parts.map { "\(label(for: $0.key))：\($0.value)" }.joined(separator: "，")
        return String(format: L10n.voiceReadbackFmt, body)
    }

    /// 编辑应用 + 全体确认（脚本预览与保存共用的唯一变换；BR-003 语义
    /// 单一维护：回读必须播报即将保存的取值）。编辑经 Domain
    /// `revise(to:)` 走修订语义，视图不直接改字段值。
    /// 审查修复（清空即删除）：用户清空的字段从确认集中移除——此前清空
    /// 被静默丢弃、原机器识别值照样保存，纠正错误识别的唯一手段反而
    /// 失效（BR-003 修正语义落空）
    private func applyingEdits() -> OcrConfirmationSet {
        var applied = set
        applied.fields = applied.fields.filter { field in
            guard let edited = edits[field.id] else { return true }
            return !edited.trimmingCharacters(in: .whitespaces).isEmpty
        }
        for i in applied.fields.indices {
            let id = applied.fields[i].id
            if let edited = edits[id] {
                _ = applied.fields[i].revise(to: edited)
            }
            _ = applied.fields[i].confirm()
        }
        return applied
    }

    private var showsAsk: Bool {
        if case .askFirst = decision { return !askAnswered }
        return false
    }

    private func binding(for field: CandidateField) -> Binding<String> {
        Binding(
            get: { edits[field.id] ?? field.value },
            set: { edits[field.id] = $0 })
    }

    /// 字段友好标签（确认卡展示用；Domain 键保持英文不兼职 UI 串）。
    /// 审查修复：此前 default 直接返回英文 Domain 键（"blood_pressure_sys"、
    /// "allergy"、'note'…），确认卡上用户看到的是未本地化的内部键——
    /// 指标键经 MetricType(grammarKey:) 单一映射取本地化名；未知键宁回原键
    /// 不编造标签。
    private func label(for key: String) -> String {
        switch key {
        case "time", "date": return L10n.voiceFieldDate
        case "hour": return L10n.voiceFieldHour
        case "repeat": return L10n.voiceFieldRepeat
        case "content", "body", "note": return L10n.voiceFieldContent
        case "allergy": return L10n.voiceguide_noteAllergy
        case "pastHistory": return L10n.voiceguide_noteHistory
        case "currentMeds": return L10n.voiceguide_noteMeds
        case "emergencyContact": return L10n.voiceguide_noteContact
        default:
            if let m = MetricType(grammarKey: key) { return L10n.metricName(m) }
            return key
        }
    }

    private var bystanderWarning: Bool {
        if case .readAloud(let warn) = decision { return warn }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                VLIcon.waveform.resizable().frame(width: 22, height: 22)
                Text(L10n.voiceConfirmTitle).font(.headline)
                Spacer()
            }

            // V3.49 判定结果行（4.27 可选元素）：去向由理解层自动判定，D 级
            // 胶囊呈现、Menu 可改类；无法判定/低置信时改渲染候选去向行内联
            // 引导（仅此状态渲染，不常驻）
            if let target = judgedTarget {
                HStack(spacing: 6) {
                    Text(L10n.voiceConfirmJudgedTarget)
                        .font(.caption).foregroundStyle(.secondary)
                    Menu {
                        ForEach(VoiceIntentDispatch.dispatchableKeys, id: \.self) { key in
                            Button(L10n.voiceIntentName(key)) {
                                onJudgedTargetChange?(key)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(L10n.voiceIntentName(target))
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)   // 触控目标 ≥44pt（ui-ux §3.3）
                        .background(Capsule().fill(Color("grade-d", bundle: .main).opacity(0.15)))
                    }
                    GradeBadge(grade: "D")
                    if judgedConfidence < 0.5 {
                        Label(L10n.voiceConfirmLowConfidence, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(Color("grade-d", bundle: .main))
                            .labelStyle(.titleAndIcon)
                    }
                    Spacer()
                }
                .accessibilityIdentifier("FR17.13.judgedTarget")
            } else if onJudgedTargetChange != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.voiceConfirmCandidates)
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(VoiceIntentDispatch.candidateKeys, id: \.self) { key in
                            Button(L10n.voiceIntentName(key)) {
                                onJudgedTargetChange?(key)
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)   // 触控目标 ≥44pt（ui-ux §3.3）
                            .background(Capsule().fill(Color("bg-grouped", bundle: .main)))
                            .overlay(Capsule().strokeBorder(
                                Color("grade-d", bundle: .main),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        }
                    }
                }
                .accessibilityIdentifier("FR17.13.targetCandidates")
            }

            // 字段列表：一律「待确认」态呈现（BR-003 未确认不入正式区）；
            // 值可编辑（未识别/识别错的字段在卡上直接补全，业界确认卡惯例）
            ForEach(set.fields) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(label(for: field.key))
                        .font(.caption).foregroundStyle(.secondary)
                    TextField(field.value.isEmpty ? L10n.voiceConfirmFillHint : field.value,
                              text: binding(for: field), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .accessibilityIdentifier("FR17.13.confirm.field.edit")
                    HStack(spacing: 6) {
                        // D 级「待确认」态经 GradeBadge 唯一渲染出口
                        // （审查修复：此前此处内联 grade-d 文案，与设计系统
                        // D/E 视觉契约双实现，徽章改版时本卡被落下）
                        GradeBadge(grade: "D")
                        if ConfidenceTier.tier(field.confidence) == .low {
                            Label(L10n.voiceConfirmLowConfidence, systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(Color("grade-d", bundle: .main))
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(Color("bg-grouped", bundle: .main)))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color("grade-d", bundle: .main),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("FR17.13.confirm.field")
            }

            if bystanderWarning {
                Label(L10n.voiceBystanderWarning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("FR17.13.bystanderWarning")
            }

            if showsAsk {
                // 三态偏好 .ask：先问一次再决定回读与否
                HStack(spacing: 12) {
                    Button {
                        askAnswered = true
                        if let script { onSpeak?(script) }
                    } label: {
                        Label(L10n.voiceAskSpeak, systemImage: "speaker.wave.2")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("FR17.13.ask.speak")
                    Button {
                        askAnswered = true
                    } label: {
                        Label(L10n.voiceAskScreen, systemImage: "speaker.slash")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("FR17.13.ask.screen")
                }
            } else if case .screenConfirm(let offerSpeak) = decision, offerSpeak {
                // 无耳机回读出口（无障碍出口，不受偏好关闭——FR17.13/F18）
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        if let script { onSpeak?(script) }
                    } label: {
                        Label(L10n.voiceSpeakAloud, systemImage: "speaker.wave.2").frame(minHeight: 44)
                    }
                    .accessibilityLabel(L10n.voiceReadAloudA11y)
                    .accessibilityIdentifier("FR17.13.speakButton")
                    Text(L10n.voiceScreenCheckHint)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button(L10n.voiceConfirmCancel, action: onCancel)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("FR17.13.cancel")
                Button(L10n.voiceConfirmRetry, action: onRetry)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("FR17.13.retry")
                Spacer()
                Button(L10n.voiceConfirmSave) {
                    // 编辑应用 + 确认走 applyingEdits 唯一变换（与回读脚本同源）
                    onConfirm(applyingEdits())
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("FR17.13.confirm")
            }
        }
        .padding(20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FR17.13.sheet")
        .overlay(alignment: .bottom) {
            if let routeToast {
                Text(routeToast)
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .accessibilityIdentifier("FR17.13.routeToast")
            }
        }
        .onAppear {
            // 有耳机（或关怀模式 always）→ 自动完整回读一次
            guard !didAutoSpeak, case .readAloud = decision, let script else { return }
            didAutoSpeak = true
            onSpeak?(script)
        }
        .onChange(of: route) { _, _ in
            showRouteToast()
        }
        .onChange(of: decision) { old, new in
            guard old != new else { return }
            // FR17.13 即时切换回读策略（此前缺失，Domain rerouted 决策零消费）：
            // ① 回读中拔耳机 → 中断播报，按新路由走屏幕核对；
            // ② 插入耳机 → 确认走回读：自动完整回读一次（onAppear 已不会重跑）。
            if old.isReadAloud, !new.isReadAloud { onStopSpeak?() }
            if !old.isReadAloud, new.isReadAloud { if let script { onSpeak?(script) } }
        }
    }

    /// 路由切换轻提示：2 秒自动消退（重叠切换时以最新为准）
    private func showRouteToast() {
        routeToast = route == .headphones ? L10n.voiceRouteHeadphonesOn : L10n.voiceRouteHeadphonesOff
        routeToastTask?.cancel()
        routeToastTask = Task { @MainActor in
            // 睡眠取消 = 换代（新的切换事件重设 Toast），预期控制流而非错误
            do { try await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { return }
            if !Task.isCancelled { routeToast = nil }
        }
    }
}

// MARK: - FR17.12 语音指导隐私与耳机提示

/// 进入语音指导模式前的一次性须知卡；确认后写入 ConsentRecord（F20.5 判定重展）。
struct VoicePrivacyHeadphoneCard: View {
    var onAccept: () -> Void
    var onUseTouch: () -> Void

    private var points: [String] {
        [L10n.voicePrivacyPoint1, L10n.voicePrivacyPoint2,
         L10n.voicePrivacyPoint3, L10n.voicePrivacyPoint4]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                VLIcon.headphone.resizable().frame(width: 28, height: 28)
                Text(L10n.voicePrivacyTitle).font(.headline)
            }
            ForEach(points, id: \.self) { p in
                HStack(alignment: .top, spacing: 8) {
                    VLIcon.checkCircle.resizable().frame(width: 16, height: 16)
                    Text(p).font(.subheadline)
                }
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 12) {
                Button(L10n.voicePrivacyUseTouch, action: onUseTouch)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("FR17.12.useTouch")
                Spacer()
                Button(L10n.voicePrivacyAccept, action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("FR17.12.accept")
            }
        }
        .padding(20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FR17.12.card")
    }
}

// MARK: - 语音受限修改拒绝卡（BR-003/006）

/// 剂量 / 频次 / 停用 —— 语音一律拒绝，改指触屏路径。
struct VoiceModificationRejectionCard: View {
    let rejection: VoiceModificationGuard.Rejection
    var onGoToPlan: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VLIcon.ban.resizable().frame(width: 24, height: 24)
                Text(L10n.voiceRejectTitle(L10n.voiceRejectWhat(rejection.category.rawValue))).font(.headline)
            }
            Text(L10n.voiceRejectBody(L10n.voiceRejectWhat(rejection.category.rawValue))).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(L10n.onboard_gotIt, action: onDismiss)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("FR17.11.reject.dismiss")
                Spacer()
                Button(L10n.voiceRejectAction, action: onGoToPlan)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("FR17.11.reject.goToPlan")
            }
        }
        .padding(20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FR17.11.rejectionCard")
    }
}

// MARK: - 统一确认卡挂载器（七处语音入口共用同一 wiring）

/// VoiceConfirmSheet 的装配单出口：回读决策（ReadbackPolicy.decide）+
/// TTS 注入 + 取消/重试语义此前在七个入口各复制一份——决策函数加参数时
/// 一处漏改即静默使用旧语义。FR17.13「唯一确认 UI」补上「唯一装配」。
struct VoiceConfirmSheetPresenter: ViewModifier {
    @Environment(AppState.self) private var app
    @Binding var confirmSet: OcrConfirmationSet?
    let route: AudioRoute
    /// V3.49 判定结果行数据（默认 nil 向后兼容——其余六处入口不渲染该行）
    let judgedTarget: String?
    let judgedConfidence: Double
    let onJudgedTargetChange: ((String) -> Void)?
    let onConfirm: (OcrConfirmationSet) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $confirmSet) { set in
            VoiceConfirmSheet(
                set: set,
                decision: ReadbackPolicy.decide(route: route,
                                                preference: app.readbackPreference,
                                                careMode: app.careMode),
                route: route,
                judgedTarget: judgedTarget,
                judgedConfidence: judgedConfidence,
                onJudgedTargetChange: onJudgedTargetChange,
                onSpeak: { app.speak($0) },
                onStopSpeak: { app.stopSpeaking() },
                onConfirm: onConfirm,
                onRetry: { confirmSet = nil },
                onCancel: { confirmSet = nil })
            .presentationDetents([.medium])
        }
    }
}

extension View {
    func voiceConfirmSheet(_ confirmSet: Binding<OcrConfirmationSet?>,
                           route: AudioRoute,
                           judgedTarget: String? = nil,
                           judgedConfidence: Double = 0,
                           onJudgedTargetChange: ((String) -> Void)? = nil,
                           onConfirm: @escaping (OcrConfirmationSet) -> Void) -> some View {
        modifier(VoiceConfirmSheetPresenter(confirmSet: confirmSet,
                                            route: route,
                                            judgedTarget: judgedTarget,
                                            judgedConfidence: judgedConfidence,
                                            onJudgedTargetChange: onJudgedTargetChange,
                                            onConfirm: onConfirm))
    }
}

// MARK: - FR17.19 期一可分发意图（4.27 判定结果行 Menu/候选行共用）

/// 期一诚实标注（FR17.19/FR14.7）：Menu 只列**有目标页消费者**的意图——
/// 预约/用药草稿期二接线后加入（能力级别标注纪律：不宣称超出当前能力）。
enum VoiceIntentDispatch {
    static let dispatchableKeys: [String] = [
        VoiceIntentKey.recordMetric.rawValue,
        VoiceIntentKey.recordObservation.rawValue,
        VoiceIntentKey.createReminder.rawValue,
        VoiceIntentKey.appendProfile.rawValue,
        VoiceIntentKey.appendNote.rawValue,
        VoiceIntentKey.askAssistant.rawValue,
        VoiceIntentKey.createQuestion.rawValue,
        VoiceIntentKey.unknown.rawValue,
    ]

    /// 低置信/无法判定时的候选去向行 = 可分发 ∩ 兜底轨可自动分类——
    /// 由意图目录 classifiableFallback 派生（Domain 单一事实源，不再手维护
    /// 第二份键表；目录增意图自动进候选行）
    static let candidateKeys: [String] = VoiceIntentCatalog.entries
        .filter { dispatchableKeys.contains($0.key.rawValue) && $0.classifiableFallback }
        .map(\.key.rawValue)
}
