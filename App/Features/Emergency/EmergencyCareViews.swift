import SwiftUI
import Domain
import Infrastructure
import Perception

/// F15 紧急信息卡（SP-15 / ui-ux §5.16）+ F18 关怀模式核心交互（§5.15）。
///
/// - 急救卡：一键置顶展示 + 系统医疗急救卡引导（只引导、不静默写入，FR15.2）
/// - SOS（FR1.8/BR-012）：**两步可达**——长按越过防误触门槛 + 二次确认；
///   SOS 路径豁免门禁（BR-012），规则在 Domain `SOSRules`，本层只渲染。

// MARK: - 急救卡

struct EmergencyCardView: View {
    let card: EmergencyCard
    var bloodType: String?
    /// 施救者第一眼需要的人别事实（2026-10-23 业主：医疗档案里已存在的
    /// 信息要反映到急救卡）。姓名来自成员档案；年龄仅在出生日期精度足够时
    /// 显示，否则显示出生年份（FR3.1），性别经 L10n 单一出口本地化。
    var patientName: String?
    var birthDate: String?
    var gender: String?
    var onGuideMedicalID: (() -> Void)?
    var onOpenSelector: (() -> Void)?
    /// 审查修复：关怀模式透传 SOS 门槛参数（原 SOSButton() 硬编码 careMode=false，
    /// 设置页展示的「SOS 门槛提升」在急救卡入口从未生效）
    var careMode: Bool = false
    /// 成员门尚未装载完成：不把「空卡」渲染成「未配置」事实（2026-10-24 呈现重设计）。
    var isLoading: Bool = false
    /// 急救卡三读失败：与「空卡」区分，显示可重试错误（2026-10-24）。
    var loadFailed: Bool = false
    var onRetry: (() -> Void)?
    /// SOS 确认后呈现求助页（第六轮全仓审查修复：急救卡 SOS 死控件接线）
    @State private var showSOSHelp = false

    private var metrics: CareModeMetrics {
        careMode ? .care : .standard
    }

    private var bloodTypeDisplay: String? {
        L10n.bloodTypeDisplayName(bloodType)
    }

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                VStack(alignment: .leading, spacing: careMode ? 16 : 12) {
                    identityHero
                    if isLoading {
                        loadingCard
                    } else {
                        if loadFailed {
                            loadFailureCard
                        }
                        // 失败且无缓存内容时不再画四节「未配置」——那会把读取
                        // 失败说成事实（BR-003 同源纪律：未确认/未知不得冒充）。
                        if !loadFailed || !EmergencyCardService.medicalIDGuideNeeded(card: card) {
                            clinicalSummaryCard
                        }
                        // 审查修复（FR15.1 死锁）：引导卡与 [管理] 曾用 else-if 互斥，
                        // 而 medicalIDGuideNeeded == 四节全空 == 全新安装的唯一状态。
                        // 于是新用户只看到「写入系统医疗急救卡」引导卡，永远拿不到
                        // 唯一的选择入口（F15.card.manage），四节永远填不上——鸡生蛋死锁，
                        // 急救卡（BR-012 唯一免门禁路径）恒为空。§5.16 要求两者并存。
                        if !loadFailed, EmergencyCardService.medicalIDGuideNeeded(card: card) {
                            GuideCard(careMode: careMode, onGuide: onGuideMedicalID)
                        }
                        if let onOpenSelector {
                            manageButton(onOpenSelector)
                        }
                    }
                    // 第六轮全仓审查修复：SOSButton 此前无 onTrigger 接线——
                    // 按住确认后执行 nil 闭包，急救卡上的 SOS 是死控件
                    // （BR-012 唯一可达路径只剩关怀悬浮球）。SOS 不随装载态隐藏。
                    SOSButton(careMode: careMode) { showSOSHelp = true }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: 672)   // ui-ux §4.4 / ADR-021：iPad 内容宽 ≤672pt
            }
            .tintedCanvas()   // ui-ux §3.0：渐变直挂容器，玻璃卡才有可感知物
            .navigationTitle(L10n.emergency_title)
            .fullScreenCover(isPresented: $showSOSHelp) {
                SOSHelpView()
            }
        }
    }

    // MARK: 人别与血型（施救者第一眼）

    /// 人别卡：姓名/年龄或出生年份/性别 + 血型。血型独立成块并保持
    /// `F15.card.bloodType` 锚点——急救场景的第一优先事实，不与正文混排。
    @ViewBuilder
    private var identityHero: some View {
        if let identity = identityLine {
            HStack(alignment: .center, spacing: 14) {
                monogram(identity.name)
                VStack(alignment: .leading, spacing: 3) {
                    Text(identity.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                    if let detail = identity.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(Color("text-secondary", bundle: .main))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("F15.card.identity")
                bloodTypeTile
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        } else if bloodTypeDisplay != nil || isLoading || loadFailed {
            // 无姓名时仍保留血型事实（不凭空补人别字段）。
            HStack {
                Spacer(minLength: 0)
                bloodTypeTile
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .glassCard()
        }
    }

    private func monogram(_ name: String) -> some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.title2.weight(.bold))
            .foregroundStyle(Color("brand-primary", bundle: .main))
            .frame(width: careMode ? 64 : 56, height: careMode ? 64 : 56)
            .background(Color("brand-primary", bundle: .main).opacity(0.12), in: Circle())
            .overlay(Circle().stroke(Color("brand-primary", bundle: .main).opacity(0.18),
                                     lineWidth: 1))
            .accessibilityHidden(true)
    }

    /// 血型块：标签 + 大数字（§3.2 metricTileValue）。未配置也显式呈现，
    /// 避免把一个空缺读成「没有血型记录」还是「页面没加载」的歧义。
    @ViewBuilder
    private var bloodTypeTile: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                VLIcon.bloodDrop.resizable().frame(width: 13, height: 13)
                Text(L10n.emergency_bloodType)
                    .font(.caption2)
                    .foregroundStyle(Color("text-secondary", bundle: .main))
            }
            if let display = bloodTypeDisplay {
                Text(display)
                    .font(VLFont.metricTileValue)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 34)
            } else if loadFailed {
                // 读取失败不等于「未配置」：显示占位破折号，不冒充事实。
                Text("—")
                    .font(VLFont.metricTileValue)
                    .foregroundStyle(Color("text-secondary", bundle: .main))
                    .frame(height: 34)
            } else {
                Text(L10n.emergency_notSet)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color("text-secondary", bundle: .main))
                    .frame(height: 34)
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: careMode ? 104 : 88, minHeight: careMode ? 76 : 68)
        .background(Color("brand-primary", bundle: .main).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: VLCornerRadius.compact, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VLCornerRadius.compact, style: .continuous)
                .stroke(Color("brand-primary", bundle: .main).opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("F15.card.bloodType")
    }

    // MARK: 临床摘要（单卡分组，玻璃层 ≤5）

    private var clinicalSummaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            section(L10n.emergencySectionAllergy, icon: "allergens",
                    items: card.allergies, emptyId: "allergy")
            sectionDivider
            section(L10n.emergencySectionMeds, icon: "pills.fill",
                    items: card.medications, emptyId: "meds")
            sectionDivider
            section(L10n.emergencySectionHealth, icon: "heart.text.square.fill",
                    items: card.healthProblems, emptyId: "health")
            sectionDivider
            section(L10n.emergencySectionContacts,
                    icon: "person.crop.circle.badge.exclamationmark",
                    items: card.contacts, emptyId: "contacts")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var sectionDivider: some View {
        Divider().opacity(0.6)
    }

    /// 节内容缩进 = 节头图标砖 24 + 间距 8：条目左缘与节标题文字对齐，
    /// 让「分类标题 → 条目」形成一眼可扫读的层级（2026-10-24 业主：
    /// 标题与正文排布不合理，按分组列表惯例收紧）。
    private var sectionContentInset: CGFloat { 24 + 8 }

    private func section(_ title: String, icon: String,
                         items: [EmergencyCardItem], emptyId: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                    .frame(width: 24, height: 24)
                    .background(Color("brand-primary", bundle: .main).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    // 节标题进 VoiceOver 转子（分组列表惯例）；不合并子元素，
                    // 「未配置」胶囊的 a11y 标识保持独立可达。
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if items.isEmpty {
                    PillBadge(text: L10n.emergency_notSet, style: .neutral, size: .regular)
                        .accessibilityIdentifier("F15.card.empty.\(emptyId)")
                } else {
                    // 入卡条目全部为已确认事实（EmergencyCardStore 只收 confirmed，
                    // FR15.1/BR-003）——节级 C 徽章，不逐行重复。
                    GradeBadge(grade: GradeBadge.gradeConfirmed)
                }
            }
            if !items.isEmpty {
                // 条目整体缩进到标题文字下方；分隔线随条目内缩（不再横贯
                // 图标列），分组边界由节间 Divider 承担。
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider().opacity(0.35)
                        }
                        itemRow(item)
                    }
                }
                .padding(.leading, sectionContentInset)
            }
        }
        .padding(.vertical, careMode ? 12 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func itemRow(_ item: EmergencyCardItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            if !item.displayDetail.isEmpty {
                Text(item.displayDetail)
                    .font(.footnote)
                    .foregroundStyle(Color("text-secondary", bundle: .main))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, careMode ? 8 : 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("F15.card.item")
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(L10n.emergencyLoading)
                .font(.subheadline)
                .foregroundStyle(Color("text-secondary", bundle: .main))
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("F15.card.loading")
    }

    private var loadFailureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color("semantic-warning", bundle: .main))
                    .accessibilityHidden(true)
                Text(L10n.emergencyLoadFailed)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let onRetry {
                Button(L10n.retry, action: onRetry)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, minHeight: metrics.touchTarget)
                    .accessibilityIdentifier("F15.card.retry")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: VLCornerRadius.compact)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("F15.card.loadFailed")
    }

    private func manageButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(L10n.emergency_manageCard, systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: metrics.touchTarget)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color("brand-primary", bundle: .main))
        .accessibilityIdentifier("F15.card.manage")
    }

    /// 人别行：姓名必填才显示；年龄优先、出生年份兜底（FR3.1），性别随档案。
    /// 每一段都是档案既有事实，本层不推断（例如缺生日不估算年龄）。
    private var identityLine: (name: String, detail: String?)? {
        let name = patientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        var parts: [String] = []
        if let age = MemberProfileCompleteness.ageYears(birthDate: birthDate) {
            parts.append(L10n.emergencyAgeFmt(age))
        } else if let year = MemberProfileCompleteness.birthYear(birthDate) {
            parts.append(L10n.emergencyBirthYearFmt(year))
        }
        if let gender, !gender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(L10n.healthGenderValue(gender))
        }
        return (name, parts.isEmpty ? nil : parts.joined(separator: " · "))
    }
}

/// FR15.2：引导用户把同样内容写入 iOS 系统医疗急救卡——分步图文引导，
/// 不替代系统能力、不静默写入；引导中断可重试。
struct GuideCard: View {
    var careMode = false
    var onGuide: (() -> Void)?
    @State private var showGuide = false

    private var metrics: CareModeMetrics {
        careMode ? .care : .standard
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "heart.text.square")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color("brand-primary", bundle: .main))
                        .frame(width: 24, height: 24)
                        .background(Color("brand-primary", bundle: .main).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityHidden(true)
                    Text(L10n.emergencyWriteTitle).font(.headline)
                    Spacer(minLength: 0)
                }
                Text(L10n.emergencyWriteSubtitle)
                    .font(.caption)
                    .foregroundStyle(Color("text-secondary", bundle: .main))
                    .fixedSize(horizontal: false, vertical: true)
                if onGuide != nil {
                    Button {
                        showGuide = true
                    } label: {
                        Label(L10n.emergencyViewGuide, systemImage: "arrow.up.forward.square")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: metrics.touchTarget)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color("brand-primary", bundle: .main))
                    .accessibilityIdentifier("F15.card.medicalIDGuide")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: VLCornerRadius.compact)   // §3.3 表面阶梯 L2（V4.05：常态无阴影）
            .sheet(isPresented: $showGuide) {
                MedicalIDGuideSheet()
            }
        }
    }
}

/// FR15.2 系统医疗急救卡分步图文引导（可重试；写入由用户在系统健康 App 手动完成）
private struct MedicalIDGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                List {
                    Section(L10n.medicalIDStep1) {
                        Text(L10n.medicalIDStep1Hint)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section(L10n.medicalIDStep2) {
                        Text(L10n.medicalIDStep2Hint)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section(L10n.medicalIDStep3) {
                        Text(L10n.medicalIDStep3Hint)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                        Button(L10n.medicalIDOpenHealth) {
                            SystemLinks.openHealthApp()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .accessibilityIdentifier("F15.card.medicalIDOpenHealth")
                    } footer: {
                        Text(L10n.medicalIDNote)
                    }
                }
                .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
                .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
                .navigationTitle(L10n.medicalIDTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.onboard_gotIt) { dismiss() }
                    }
                }
            }
        }
    }
}

// MARK: - 卡片内容选择（FR15.1 默认收录，显式退选才排除）

/// 候选清单 → 用户逐项退选/恢复。勾选状态由 `EmergencyCardStore.selected` 提供，
/// 本视图只负责呈现与调用选择/退选——档案已确认条目默认入卡（v44）。
struct EmergencyCardSelectorView: View {
    let candidates: EmergencyCard
    let selectedIds: Set<UUID>
    var onToggle: ((EmergencyCardItem, Bool) -> Void)?

    var body: some View {
        WithPerceptionTracking {
            List {
                selectorSection(L10n.emergencySectionAllergy, items: candidates.allergies)
                selectorSection(L10n.emergencySectionMeds, items: candidates.medications)
                selectorSection(L10n.emergencySectionHealth, items: candidates.healthProblems)
                selectorSection(L10n.emergencySectionContacts, items: candidates.contacts)
                // 2026-10-23 业主：联系人不能只在注册流录入——选择页直达管理，
                // 新增后立即成为候选（M2HubStore 写后刷新候选与已选）。
                if onToggle != nil {
                    Section {
                        NavigationLink {
                            EmergencyContactListView()
                        } label: {
                            Label(L10n.emergencyContactsManage,
                                  systemImage: "person.crop.circle.badge.plus")
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("F15.selector.manageContacts")
                    } footer: {
                        Text(L10n.emergencyContactsHint)
                    }
                }
            }
            .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
            .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
            .navigationTitle(L10n.emergencySelectTitle)
        }
    }

    private func selectorSection(_ title: String, items: [EmergencyCardItem]) -> some View {
        Section(title) {
            if items.isEmpty {
                Text(L10n.emergencyNoCandidates).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    Button {
                        onToggle?(item, !selectedIds.contains(item.id))
                    } label: {
                        HStack {
                            VLIcon.checkCircle.resizable().frame(width: 20, height: 20)
                                .opacity(selectedIds.contains(item.id) ? 1 : 0.2)
                            VStack(alignment: .leading) {
                                Text(item.title)
                                if !item.displayDetail.isEmpty {
                                    Text(item.displayDetail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
                    .accessibilityLabel("\(item.title)：\(selectedIds.contains(item.id) ? L10n.emergencySelected : L10n.emergencyUnselected)")
                    .accessibilityIdentifier("F15.selector.item")
                }
            }
        }
    }
}

// MARK: - SOS 两步可达（BR-012 豁免门禁）

/// 长按越过防误触门槛（关怀模式下门槛更高），再二次确认。
/// 规则全在 Domain `SOSRules`——本视图零业务判断。
struct SOSButton: View {
    var careMode = false
    var onTrigger: (() -> Void)?

    @State private var holdConfirmed = false

    private var metrics: CareModeMetrics {
        careMode ? CareModeMetrics.care : CareModeMetrics.standard
    }

    private var requiredHold: TimeInterval {
        SOSRules.requiresHoldConfirm("sos", mode: metrics)
            ? HoldToConfirm.requiredSeconds(mode: metrics)
            : 1.0
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 8) {
                if !holdConfirmed {
                    Button {
                        // 触发由长按手势承担；点按给轻提示（Touch target ≥44pt，关怀 ≥64pt）
                    } label: {
                        Text(L10n.emergency_sos_hold)
                            .font(careMode ? .title3 : .body)
                            .frame(minWidth: careMode ? 200 : 160,
                                   minHeight: careMode ? 64 : 44)
                            .background(RoundedRectangle(cornerRadius: 14)
                                .fill(Color("semantic-danger", bundle: .main)))
                            .foregroundStyle(.white)
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: requiredHold)
                            .onEnded { _ in holdConfirmed = true }
                    )
                    // 审查修复（BR-012 辅助功能通路）：VoiceOver 用户无法执行长按，
                    // 双击默认动作等效激活 SOS——关怀模式恰是面向弱能力用户的场景
                    .accessibilityAction { holdConfirmed = true }
                    .accessibilityLabel(L10n.emergency_sos_holdA11y(requiredHold))
                    .accessibilityIdentifier("F15.card.sos.hold")
                } else {
                    Text(L10n.emergency_sos_confirmPrompt)
                        .font(.headline)
                        .accessibilityIdentifier("F15.card.sos.confirmPrompt")
                    HStack(spacing: 16) {
                        Button(L10n.emergency_sos_cancel) { holdConfirmed = false }
                            .frame(minHeight: careMode ? 64 : 44)
                            .accessibilityIdentifier("F15.card.sos.cancel")
                        Button(L10n.emergency_sos_confirm) { onTrigger?() }
                            .buttonStyle(.borderedProminent)
                            .tint(Color("semantic-danger", bundle: .main))
                            .frame(minHeight: careMode ? 64 : 44)
                            .accessibilityIdentifier("F15.card.sos.confirm")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - FR18.6 SOS 常驻悬浮球（关怀模式右下角；按住确认 + 环形进度反馈）

/// SOS 悬浮球：长按越过防误触门槛（环形进度反馈 FR18.3），松手进入求助页。
/// 半透明；任意页面可达（挂在根视图 overlay）；求助页零门禁（FR1.8）。
struct SOSOrb: View {
    @State private var showHelp = false

    // FR18.3 按住确认 ≥600ms——阈值来自 Domain 单一事实源（CareModeMetrics
    // 关怀档，SOSButton 同源），此前 0.6 硬编码：关怀门槛调参时两处漂移
    private let requiredHold: TimeInterval = HoldToConfirm.requiredSeconds(mode: CareModeMetrics.care)

    var body: some View {
        WithPerceptionTracking {
            // S-1（第九轮审查）：按住计时/进度环/位移取消/Haptics 完成触觉
            // 下沉共享原语 HoldToConfirmRing（本视图是其行为基线出处；
            // 关怀 SOS 大卡与时段卡 [全部已服用] 同源复用）。
            HoldToConfirmRing(requiredSeconds: requiredHold,
                              maxTravel: CareModeMetrics.care.sosOrbMaxTravelPoints,
                              cornerRadius: nil,
                              ringColor: .white) {
                ZStack {
                    // V4.06 重设计（业主 2026-09-24）：圆 + 圆内文字 = 文字溢出 64pt 圆；
                    // 改**胶囊形**（图标 + 单行文字在内部，不再溢出），高度 64 保持
                    // 关怀触点 ≥64pt（FR18.2），宽度随内容。
                    Capsule()
                        // 第八轮修复：语义危险色令牌替代硬编码 Color.red（§3.1
                        // 语义色表：semantic/danger = 紧急/SOS 专用，深色模式自动映射）
                        .fill(Color("semantic-danger", bundle: .main).opacity(0.9))
                        .frame(height: 64)
                        .shadow(radius: 6)
                    HStack(spacing: 6) {
                        Image(systemName: "sos")
                            .font(.title3.bold())
                        Text(L10n.emergency_sos_hold)
                            .font(.caption.bold())
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                }
                .opacity(0.9)   // 可半透明（FR18.6）
            } onComplete: {
                showHelp = true
            }
            // 审查修复（BR-012 辅助功能通路）：VoiceOver 双击等效激活求助页
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(L10n.emergency_sos_holdA11y(requiredHold))
            .accessibilityAction { showHelp = true }
            .fullScreenCover(isPresented: $showHelp) {
                SOSHelpView()
            }
            // 审查修复：删除重复的 .accessibilityLabel(sosHelpTitle)——同一视图
            // 连续两次 label，后者覆盖前者：VoiceOver 用户失去「按住 N 秒」
            // 时长指导（BR-012 辅助功能通路的刻意产物被吞）。
        }
    }
}

// MARK: - SOS 全屏求助页（FR18.6 · BR-012 唯一免门禁路径）

/// FR18.6 全屏求助页：拨打电话 / 查看急救卡 / 发送位置（P1 置灰说明）。
/// **不设门禁**（安全优先于隐私，FR1.8 唯一豁免）；任意页面 ≤2 步可达
/// （锁屏遮罩 SOSButton → 本页；本页内一步即达三个动作）。
/// 紧急联系人来自 F15 急救卡已确认数据源（BR-003 未确认不入卡）。
struct SOSHelpView: View {
    @Environment(AppState.self) private var app
    @Environment(M2HubStore.self) private var hub
    @State private var showEmergencyCard = false
    /// 第九轮审查修复（HIG Modality）：本视图经 fullScreenCover 呈现
    /// （SOSOrb / EmergencyCardView / 锁屏 SOS），fullScreenCover **无** swipe
    /// 关闭——此前页内除拨号/查看卡外无任何退出键，关怀模式用户（SOS 目标
    /// 人群）会被困在该全屏页只能强杀。补显式关闭按钮（一处修复覆盖全部入口）。
    @Environment(\.dismiss) private var dismiss
    /// BR-012：拨号失败必须可见（不得静默死控件）
    @State private var dialFailed = false

    private var contacts: [EmergencyCardItem] {
        hub.emergencySelected.contacts.filter(\.confirmed)
    }

    /// 成员门：未装载完成前不得把「尚无联系人」当作事实（BR-001）。
    private var contactsLoaded: Bool {
        hub.isLoaded(for: app.currentPatientId)
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                VStack(spacing: 20) {
                    Text(L10n.sosHelpTitle)
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("F18.sos.title")

                    // 拨打 120：一步直达（免复述——紧急优先；FR19 附表语义一致）
                    Button {
                        dial(L10n.emergencyNumber)   // 审查修复：号码按语言区域取 L10n
                    } label: {
                        Label(L10n.sosCall120, systemImage: "phone.fill")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("semantic-danger", bundle: .main))
                    .accessibilityIdentifier("F18.sos.call120")

                    // 紧急联系人（已配置才显示；未配置引导去急救卡补录，FR15.1）。
                    // 装载中/失败不显示「无联系人」——那是把未知冒充事实。
                    if !contactsLoaded {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(L10n.emergencyLoading)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("F18.sos.contactsLoading")
                    } else if hub.emergencyLoadFailed {
                        VStack(spacing: 6) {
                            Text(L10n.emergencyLoadFailed)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button(L10n.retry) {
                                Task { await hub.load(patientId: app.currentPatientId, force: true) }
                            }
                            .accessibilityIdentifier("F18.sos.contactsRetry")
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("F18.sos.contactsLoadFailed")
                    } else if contacts.isEmpty {
                        Text(L10n.sosNoContacts)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("F18.sos.noContacts")
                    } else {
                        ForEach(contacts) { contact in
                            if let phone = contact.contactPhone, !phone.isEmpty {
                                Button {
                                    // BR-012 SOS 路径不得因 CJK/分隔符使 tel: 失效
                                    dial(phone)
                                } label: {
                                    Label(contact.title, systemImage: "person.crop.circle.badge.exclamationmark")
                                        .frame(maxWidth: .infinity, minHeight: 56)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("F18.sos.contact")
                            } else {
                                // 无号码联系人不得渲染成可拨死控件（BR-012）。
                                Label(contact.title, systemImage: "person.crop.circle")
                                    .frame(maxWidth: .infinity, minHeight: 56)
                                    .accessibilityIdentifier("F18.sos.contactNoPhone")
                            }
                        }
                    }

                    // 查看急救卡（F15 配置与展示）
                    Button {
                        showEmergencyCard = true
                    } label: {
                        Label(L10n.sosViewCard, systemImage: "cross.case.fill")
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("F18.sos.viewCard")

                    // 发送位置（P1，置灰说明——不假装可用）
                    Label(L10n.sosSendLocationP1, systemImage: "location.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("F18.sos.sendLocationP1")

                    Spacer()
                }
                .padding(24)
                .navigationTitle(L10n.sosHelpTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // BR-012 路径的退出键：轻点即可返回（≥44pt 系统栏默认达标）
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.commonClose) { dismiss() }
                            .accessibilityIdentifier("F18.sos.close")
                    }
                }
                .sheet(isPresented: $showEmergencyCard) {
                    // 全仓审查 2026-09-18（F-A2-02，P0）：SOS 路径可在锁屏未认证时到达——
                    // 急救卡只读呈现（旁人施救所需的血型/过敏/用药/联系人），[管理] 不出现
                    NavigationStack { EmergencyCardHubView(readOnly: true) }
                }
                .task(id: app.currentPatientId) { await hub.load(patientId: app.currentPatientId) }
                .alert(L10n.sosDialFailed, isPresented: $dialFailed) {
                    Button(L10n.onboard_gotIt, role: .cancel) { }
                }
            }
        }
    }

    /// 系统拨号：经 SystemLinks 单一出口（号码归一，全仓审查 2026-09-18 F-A2-05）；
    /// 拨号动作本身由系统确认，App 不拦截不记录内容。
    /// 审查修复（BR-012）：返回值此前被丢弃——iPad（无电话 App，canOpenURL 恒假）
    /// 或号码含分隔符表外字符（PhoneNumberRules.dialable 归一失败）时，
    /// [拨打 120] 与联系人按钮变成静默死控件：不拨号、不报错、不提示，
    /// 用户在急救场景下以为已拨出。SOS 是唯一免门禁路径，其失败必须响亮可见。
    /// 对照正确写法：VoiceSessionView.swift:780 `if !SystemLinks.dial(phone) { 提示 }`。
    private func dial(_ number: String) {
        if !SystemLinks.dial(number) { dialFailed = true }
    }
}

// MARK: - 关怀模式（F18 核心）

/// 关怀模式设置与展示参数（§5.15/§5.16）。
/// M2 范围：设置开关 + 触点/字号放大参数 + 语音优先默认 + SOS 门槛提升；
/// 语音任务引导服务（FR18.12-15）随 TaskGuideService 在本阶段后接。
struct CareModeSettingsView: View {
    @Environment(AppState.self) private var app
    @State private var careMode = false

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { careMode },
                        set: { newValue in
                            careMode = newValue
                            app.careMode = newValue
                        })) {
                        Label(L10n.care_title, systemImage: "eye")
                    }
                    .accessibilityIdentifier("F18.care.toggle")
                } footer: {
                    Text(L10n.care_footer)
                }
                if careMode {
                    Section(L10n.care_parameters_section) {
                        LabeledContent(L10n.care_parameters_touchTarget, value: "≥64 pt")
                        LabeledContent(L10n.care_parameters_speechRate, value: L10n.care_parameters_valueSlow)
                        LabeledContent(L10n.care_parameters_readback, value: L10n.care_parameters_valueAskEachTime)
                        LabeledContent(L10n.care_parameters_voiceInput, value: L10n.care_parameters_valueDefaultOn)
                        LabeledContent(L10n.care_parameters_sos,
                                       value: L10n.careParametersSOSValue(seconds: Int(HoldToConfirm.requiredSeconds(mode: CareModeMetrics.care))))
                    }
                    .accessibilityIdentifier("F18.care.parameters")
                }
            }
            .navigationTitle(L10n.care_title)
            .onAppear { careMode = app.careMode }
        }
    }
}


// MARK: - 急救卡条目展示组装（L10n 单出口）

private extension EmergencyCardItem {
    /// 展示 detail：结构化字段经 L10n 组装——存储层不再拼中文展示串
    /// （「反应：… · 严重度 …」「关系 · 电话」此前硬编码在
    /// EmergencyCardStore，zh-Hant/en 用户看到简体残留）
    var displayDetail: String {
        switch kind {
        case "allergy":
            var parts: [String] = []
            // 第九轮审查修复（施救人阅读面，评审实据）：
            // ① reaction_tags 是 **JSON 数组列**（ObservationStore 存
            //    JSONEncoder 结果、资料建议路径存 "[]"）——此前原样上屏，
            //    急救卡显示「反应：["皮疹","过敏性休克"]」甚至「反应：[]」。
            //    按列表页同款纪律解码；"[]"/空 → 不占位；旧纯文本值透传。
            // ② severity 列是 canonical 英文（mild/moderate/severe）——此前直出
            //    「严重度：severe」；经 L10n.allergySeverity（列表页同款
            //    displaySeverity 出口）本地化后再组装。
            if let reaction, !reaction.isEmpty {
                let decoded: String? = {
                    guard let data = reaction.data(using: .utf8),
                          let tags = try? JSONDecoder().decode([String].self, from: data) else { return reaction }   // try?-ok: 非 JSON 旧值按原文透传
                    let cleaned = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    return cleaned.isEmpty ? nil : cleaned.joined(separator: "、")
                }()
                if let decoded { parts.append(L10n.emergencyReaction(decoded)) }
            }
            if let severity, !severity.isEmpty {
                parts.append(L10n.emergencySeverity(L10n.allergySeverity(severity)))
            }
            return parts.joined(separator: " · ")
        case "contact":
            // 关系与号码各自独立可用：任一为空时仍展示另一个（此前要求二者
            // 同时存在，只有关系或只有号码的联系人在急救卡上只剩姓名——
            // 施救者拿不到可拨号码）。关系统一经 memberRelationDisplayName
            // 单一出口（三语本地化 + en 首字母大写）。
            var parts: [String] = []
            if let relation, !relation.isEmpty {
                parts.append(L10n.memberRelationDisplayName(relation))
            }
            if let phone, !phone.isEmpty {
                parts.append(phone)
            }
            return parts.isEmpty ? detail : parts.joined(separator: " · ")
        case "healthProblem":
            // 慢性病/手术史 kind 为 canonical 英文（chronic/surgery），
            // 展示层经 L10n 单一出口；未知值原样返回，不猜。
            switch detail {
            case "chronic": return L10n.healthHistoryChronic
            case "surgery": return L10n.healthHistorySurgery
            default: return detail
            }
        default:
            return detail
        }
    }
}
