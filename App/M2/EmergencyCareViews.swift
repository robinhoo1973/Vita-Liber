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
                        Label("管理卡片内容", systemImage: "pencil").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("F15.card.manage")
                }
                SOSButton()
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

/// FR15.2：引导用户把同样内容写入 iOS 系统医疗急救卡——分步引导，
/// 不替代系统能力、不静默写入。
private struct GuideCard: View {
    var onGuide: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.emergencyWriteTitle).font(.headline)
            Text(L10n.emergencyWriteSubtitle)
                .font(.caption).foregroundStyle(.secondary)
            if let onGuide {
                Button(L10n.emergencyViewGuide, action: onGuide)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("F15.card.medicalIDGuide")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color("bg-grouped", bundle: .main)))
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
                .accessibilityLabel("紧急求助：长按 \(Int(requiredHold)) 秒激活")
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
