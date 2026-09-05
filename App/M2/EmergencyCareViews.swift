import SwiftUI
import Domain
import Infrastructure

/// F15 紧急信息卡（SP-15 / ui-ux §5.16）+ F18 关怀模式核心交互（§5.15）。
///
/// - 急救卡：一键置顶展示 + 系统医疗急救卡引导（只引导、不静默写入，FR15.2）
/// - SOS（FR1.8/BR-012）：**两步可达**——长按越过防误触门槛 + 二次确认；
///   SOS 路径豁免门禁（BR-012），规则在 Domain `SOSRules`，本层只渲染。

// MARK: - 急救卡

struct EmergencyCardView: View {
    let card: EmergencyCard
    var bloodType: String?
    var onGuideMedicalID: (() -> Void)?
    var onOpenSelector: (() -> Void)?
    /// 审查修复：关怀模式透传 SOS 门槛参数（原 SOSButton() 硬编码 careMode=false，
    /// 设置页展示的「SOS 门槛提升」在急救卡入口从未生效）
    var careMode: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    VLIcon.emergencyCard.resizable().frame(width: 28, height: 28)
                    Text(L10n.emergency_title).font(.title2).bold()
                    Spacer()
                }
                if let bloodType, !bloodType.isEmpty {
                    CardRow(icon: VLIcon.bloodDrop, title: L10n.emergency_bloodType, value: bloodType)
                        .accessibilityIdentifier("F15.card.bloodType")
                }
                section(L10n.emergency_allergy, items: card.allergies, empty: L10n.emergency_notSet)
                section(L10n.emergency_meds, items: card.medications, empty: L10n.emergency_notSet)
                section(L10n.emergency_health, items: card.healthProblems, empty: L10n.emergency_notSet)
                section(L10n.emergency_contacts, items: card.contacts, empty: L10n.emergency_notSet)

                if EmergencyCardService.medicalIDGuideNeeded(card: card) {
                    GuideCard(onGuide: onGuideMedicalID)
                } else if let onOpenSelector {
                    Button {
                        onOpenSelector()
                    } label: {
                        Label(L10n.emergency_manageCard, systemImage: "pencil").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("F15.card.manage")
                }
                SOSButton(careMode: careMode)
                Spacer()
            }
            .padding(16)
        }
        .navigationTitle(L10n.emergency_title)
    }

    private func section(_ title: String, items: [EmergencyCardItem], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if items.isEmpty {
                Text(empty).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("F15.card.empty.\(title)")
            } else {
                ForEach(items) { item in
                    HStack {
                        Text(item.title).font(.subheadline)
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("F15.card.item")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CardRow: View {
    let icon: Image
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            icon.resizable().frame(width: 22, height: 22)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title3).monospacedDigit()
        }
        .frame(minHeight: 44, alignment: .leading)
    }
}

/// FR15.2：引导用户把同样内容写入 iOS 系统医疗急救卡——分步图文引导，
/// 不替代系统能力、不静默写入；引导中断可重试。
struct GuideCard: View {
    var onGuide: (() -> Void)?
    @State private var showGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.emergencyWriteTitle).font(.headline)
            Text(L10n.emergencyWriteSubtitle)
                .font(.caption).foregroundStyle(.secondary)
            if let onGuide {
                Button(L10n.emergencyViewGuide) {
                    showGuide = true
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("F15.card.medicalIDGuide")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color("bg-grouped", bundle: .main)))
        .sheet(isPresented: $showGuide) {
            MedicalIDGuideSheet()
        }
    }
}

/// FR15.2 系统医疗急救卡分步图文引导（可重试；写入由用户在系统健康 App 手动完成）
private struct MedicalIDGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
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
                        if let url = URL(string: "x-apple-health://") {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .accessibilityIdentifier("F15.card.medicalIDOpenHealth")
                } footer: {
                    Text(L10n.medicalIDNote)
                }
            }
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

// MARK: - 卡片内容选择（FR15.1 逐项选择，不静默加入）

/// 候选清单 → 用户逐项勾选。勾选状态由 `EmergencyCardStore.selected` 提供，
/// 本视图只负责呈现与调用选择/退选——**数据存在 ≠ 同意入卡**。
struct EmergencyCardSelectorView: View {
    let candidates: EmergencyCard
    let selectedIds: Set<UUID>
    var onToggle: ((EmergencyCardItem, Bool) -> Void)?

    var body: some View {
        List {
            selectorSection(L10n.emergencySectionAllergy, items: candidates.allergies)
            selectorSection(L10n.emergencySectionMeds, items: candidates.medications)
            selectorSection(L10n.emergencySectionHealth, items: candidates.healthProblems)
            selectorSection(L10n.emergencySectionContacts, items: candidates.contacts)
        }
        .navigationTitle(L10n.emergencySelectTitle)
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
                                if !item.detail.isEmpty {
                                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
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
    @State private var holdStart: Date?
    @State private var holdProgress: Double = 0

    private var metrics: CareModeMetrics {
        careMode ? CareModeMetrics.care : CareModeMetrics.standard
    }

    private var requiredHold: TimeInterval {
        SOSRules.requiresHoldConfirm("sos", mode: metrics)
            ? HoldToConfirm.requiredSeconds(mode: metrics)
            : 1.0
    }

    var body: some View {
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
                            .fill(Color.red.opacity(0.9)))
                        .foregroundStyle(.white)
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: requiredHold)
                        .onEnded { _ in holdConfirmed = true }
                )
                // 审查修复（BR-012 辅助功能通路）：VoiceOver 用户无法执行长按，
                // 双击默认动作等效激活 SOS——关怀模式恰是面向弱能力用户的场景
                .accessibilityAction { holdConfirmed = true }
                .accessibilityLabel(L10n.emergency_sos_holdA11y(Int(requiredHold)))
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
                        .tint(.red)
                        .frame(minHeight: careMode ? 64 : 44)
                        .accessibilityIdentifier("F15.card.sos.confirm")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - FR18.6 SOS 常驻悬浮球（关怀模式右下角；按住确认 + 环形进度反馈）

/// SOS 悬浮球：长按越过防误触门槛（环形进度反馈 FR18.3），松手进入求助页。
/// 半透明；任意页面可达（挂在根视图 overlay）；求助页零门禁（FR1.8）。
struct SOSOrb: View {
    @State private var holdStart: Date?
    @State private var showHelp = false

    private let requiredHold: TimeInterval = 0.6   // FR18.3 按住确认 ≥600ms

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.85))
                .frame(width: 64, height: 64)   // 关怀触点 ≥64pt（FR18.2）
                .shadow(radius: 6)
            // 环形进度反馈（FR18.3 按住确认的环形进度）
            if let start = holdStart {
                Circle()
                    .trim(from: 0, to: progress(start))
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(-90))
            }
            Text(L10n.emergency_sos_hold)
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .opacity(0.9)   // 可半透明（FR18.6）
        .simultaneousGesture(
            LongPressGesture(minimumDuration: requiredHold)
                .onChanged { _ in holdStart = Date() }
                .onEnded { _ in
                    holdStart = nil
                    showHelp = true
                }
        )
        // 审查修复（BR-012 辅助功能通路）：VoiceOver 双击等效激活求助页
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(L10n.emergency_sos_holdA11y(Int(requiredHold)))
        .accessibilityAction { showHelp = true }
        .fullScreenCover(isPresented: $showHelp) {
            SOSHelpView()
        }
        .accessibilityLabel(L10n.sosHelpTitle)
    }

    private func progress(_ start: Date) -> CGFloat {
        min(1, Date().timeIntervalSince(start) / requiredHold)
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

    private var contacts: [EmergencyCardItem] {
        hub.emergencySelected.contacts.filter(\.confirmed)
    }

    var body: some View {
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
                .tint(.red)
                .accessibilityIdentifier("F18.sos.call120")

                // 紧急联系人（已配置才显示；未配置引导去急救卡补录，FR15.1）
                if contacts.isEmpty {
                    Text(L10n.sosNoContacts)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("F18.sos.noContacts")
                } else {
                    ForEach(contacts) { contact in
                        Button {
                            dial(contact.detail)
                        } label: {
                            Label(contact.title, systemImage: "person.crop.circle.badge.exclamationmark")
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("F18.sos.contact")
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
            .sheet(isPresented: $showEmergencyCard) {
                NavigationStack { EmergencyCardHubView() }
            }
            .task(id: app.currentPatientId) { await hub.load(patientId: app.currentPatientId) }
        }
    }

    /// 系统拨号（tel://）：拨号动作本身由系统确认，App 不拦截不记录内容
    private func dial(_ number: String) {
        guard let url = URL(string: "tel://\(number)"),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
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
                                   value: L10n.care_parameters_sosValue(seconds: Int(HoldToConfirm.requiredSeconds(mode: CareModeMetrics.care))))
                }
                .accessibilityIdentifier("F18.care.parameters")
            }
        }
        .navigationTitle(L10n.care_title)
        .onAppear { careMode = app.careMode }
    }
}
