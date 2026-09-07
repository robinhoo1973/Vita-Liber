import SwiftUI
import Domain

/// FR17.9 全局语音快速入口（SP-55 语音速记面板 · ui-ux §5.54）：
/// 目标 chips（指标 / 观察 / 问诊问题 / AI 提问 / 提醒设定 / 档案设定 / 任意文本），
/// 上下文感知默认高亮当前页相关目标，可一键切换。
/// 仅限受限文法与结构化录入，不做自由对话（F19 边界延续）。
///
/// **§5.54 契约（V3.71 修复）**：面板自身承载录音环节——chips → 按住说话
/// （波形+实时转写）→ 结构化草稿卡（按目标经 VoiceStructuringEngine 抽取）
/// → FR17.13 统一确认模板 → 按目标分发（任意文本 = 面板内直接落 VoiceNote；
/// 其余目标 = 确认字段经 AppRouter.pendingVoiceDraft 暂存后跳转目标页预填）。
/// 此前实现为「chips + 开始跳转」的路由中转，中部录音环节整体缺失——
/// 5.50 登记表按父 SP 覆盖校验掩盖了组件粒度缺失（面板无任何录音按钮）。
struct VoiceQuickLaunchView: View {
    @Environment(AppState.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(VoiceNoteState.self) private var voiceNoteState
    @Environment(\.dismiss) private var dismiss

    @State private var target: L10n.TargetTag = .anyText
    /// 第八轮全仓审查修复（FR17.9 V3.40 定案）：chips 由「前置必选」降级为
    /// 「自动判定 + 消歧兜底」——用户未显式点过 chip 时按识别文本自动判定
    /// 意图（三套文法并行抽取、命中多者胜）；用户点 chip = 显式覆盖自动判定。
    @State private var userPickedTarget: L10n.TargetTag?
    @State private var confirmSet: OcrConfirmationSet?
    @State private var savedNote = false
    @State private var routeMonitor = AudioRouteMonitor()

    /// 生效目标 = 显式选择覆盖自动判定。合并表达式此前在 chips 高亮/
    /// dispatch/导航三处各复制一份 `userPickedTarget ?? target`——语义
    /// 只维护这一处，新增消费点不再有遗漏风险。
    private var effectiveTarget: L10n.TargetTag { userPickedTarget ?? target }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(L10n.voicePanelTitle)
                    .font(.title2.bold())
                Text(L10n.voicePanelHint)
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                // 目标 chips 横排（换行布局）——预选高亮 = 自动判定结果或
                // 用户显式选择，可一键覆盖（消歧兜底，非前置必选）
                FlowChips(
                    items: L10n.TargetTag.allCases.map { (title: L10n.voiceTargetName($0), tag: $0) },
                    selected: effectiveTarget
                ) { selected in
                    userPickedTarget = selected
                }
                // §5.54 中部录音环节：按住说话 + 实时转写（组件自带部分文本/失败态/
                // 授权关闭回落提示）；完成回调按目标抽取结构化草稿 → 确认卡
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
                    confirmSet = VoiceInputTemplate.confirmationSet(
                        drafts: drafts(for: text, confidence: confidence))
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
            .voiceConfirmSheet($confirmSet, route: routeMonitor.route) { confirmed in
                confirmSet = nil
                dispatch(confirmed)
            }
            .alert(L10n.voicePanelSaved, isPresented: $savedNote) {
                Button(L10n.voicenoteView) { router.navigate(to: .voiceNotePanel) }
                Button(L10n.onboard_gotIt, role: .cancel) {}
            }
        }
        .presentationDetents([.medium])
    }

    /// 按目标抽取结构化草稿（§5.54「结构化草稿卡」）；抽取零命中回落纯文本
    /// 草稿（确认卡可编辑补全——绝不静默丢弃转写，FR17.13 编辑语义）。
    /// 第八轮全仓审查修复（FR17.9 自动判定）：用户未显式点 chip 时，三套
    /// 文法并行抽取、按命中数自动判定意图（第一选择）并同步高亮 chips；
    /// 全零命中回落 note 草稿（FR17.19 unknown 语义：整句原文进速记）。
    private func drafts(for text: String, confidence: Double) -> [FieldDraft] {
        if let picked = userPickedTarget {
            return Self.extract(for: picked, text: text, confidence: confidence)
        }
        let candidates: [(L10n.TargetTag, [FieldDraft])] = [
            (.metric, VoiceStructuringEngine.extractMetric(text, rules: VoiceGrammarDefaults.metricRules)),
            (.reminder, VoiceStructuringEngine.extractReminder(text, rules: VoiceGrammarDefaults.reminderRules)),
            (.profile, VoiceStructuringEngine.extractProfile(text, rules: VoiceGrammarDefaults.profileRules)),
        ]
        if let best = candidates.max(by: { $0.1.count < $1.1.count }), !best.1.isEmpty {
            target = best.0   // chips 预选猜测随自动判定高亮（用户可一键覆盖）
            return best.1
        }
        target = .anyText
        return [VoiceInputTemplate.fallbackDraft(value: text, confidence: confidence)]
    }

    /// 显式 chip 抽取（消歧兜底）：observation/question/ai 无独立文法，
    /// 回落纯文本草稿（原语义不变）
    private static func extract(for picked: L10n.TargetTag, text: String,
                                confidence: Double) -> [FieldDraft] {
        let extracted: [FieldDraft]
        switch picked {
        case .metric:
            extracted = VoiceStructuringEngine.extractMetric(text, rules: VoiceGrammarDefaults.metricRules)
        case .reminder:
            extracted = VoiceStructuringEngine.extractReminder(text, rules: VoiceGrammarDefaults.reminderRules)
        case .profile:
            extracted = VoiceStructuringEngine.extractProfile(text, rules: VoiceGrammarDefaults.profileRules)
        case .anyText, .observation, .question, .ai:
            extracted = []
        }
        return extracted.isEmpty
            ? [VoiceInputTemplate.fallbackDraft(value: text, confidence: confidence)]
            : extracted
    }

    /// 确认后分发（§5.54）：任意文本 = 面板内落 VoiceNote + 已存提示（[查看]
    /// 直达 SP-59）；其余目标 = 确认字段经 pendingVoiceDraft 暂存后跳目标页预填。
    /// 分发目标 = 用户显式 chip 覆盖，否则自动判定结果（FR17.9）。
    private func dispatch(_ set: OcrConfirmationSet) {
        let fields = set.confirmedFields
        let map = set.keyedValues
        switch effectiveTarget {
        case .anyText:
            guard let body = fields.first?.value, !body.isEmpty else { return }
            Task {
                // 审查修复：写失败不得弹「已保存」——create 返回成败，
                // [查看] 直达的列表里没有这条速记会当场露馅（假事实）
                savedNote = await voiceNoteState.create(patientId: app.currentPatientId, body: body, tags: nil)
            }
        default:
            // 只对「有消费方」的目标暂存草稿——指标/提醒/档案三入口已接
            // pendingVoiceDraft 一次性投递；观察/问诊/AI 尚无消费方（§11
            // 登记技术债），写入只会滞留并被**下一次**指标快速录入误消费，
            // 把旧目标的确认值填进指标表单（假读数入库）
            if [.metric, .reminder, .profile].contains(effectiveTarget) {
                router.pendingVoiceDraft = map
            }
            open(effectiveTarget)
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

/// 简易 chips 流式布局（VoiceQuickLaunch 目标选择）
private struct FlowChips<T: Hashable>: View {
    let items: [(title: String, tag: T)]
    let selected: T
    let onSelect: (T) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.tag) { item in
                Button {
                    onSelect(item.tag)
                } label: {
                    Text(item.title)
                        .font(.subheadline)
                        .frame(minHeight: 44)   // 触控目标 ≥44pt（ui-ux §3.3，此前 ~40pt）
                        .padding(.horizontal, 14)
                        .background(Capsule().fill(selected == item.tag
                                                   ? Color("brand-primary", bundle: .main)
                                                   : Color(.systemGray5)))
                        .foregroundStyle(selected == item.tag ? .white : .primary)
                }
                .buttonStyle(.plain)
                // 审查修复：hashValue 每进程随机（SipHash），自动化/辅助功能
                // 无法稳定寻址——用 rawValue 描述作为确定性标识
                .accessibilityIdentifier("SP-55.panel.chip.\(String(describing: item.tag))")
            }
        }
        .padding(.horizontal, 24)
    }
}

/// iOS 16+ Layout 协议流式布局（行内换行 chips）
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
