import SwiftUI
import Domain

/// F14 设置中心（SP 系列 M1c 切片）：分目的授权九开关（FR14.1 独立开关语义）、
/// 常用习惯（FR14.7）、审计与关于入口。
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(AppSettingsStore.self) private var settings
    @State private var toggles: [AppSettingKey: Bool] = [:]

    var body: some View {
        Form {
            Section(L10n.settings_authTitle) {
                ForEach(authKeys, id: \.rawValue) { key in
                    Toggle(isOn: binding(for: key)) {
                        Text(label(for: key))
                    }
                    .accessibilityIdentifier("SP-25.setting.\(key.rawValue)")
                }
            }
            // FR14.4 外观与主题（§5.12.1：三段选择器 + 高对比度开关；位置对齐 mock 我的页）
            Section {
                ThemeSegmentedPicker(selection: themeBinding)
                Toggle(isOn: binding(for: .highContrastEnabled)) {
                    Text(L10n.settings_highContrast)
                }
                .accessibilityIdentifier("SP-25.setting.highContrast")
            } header: {
                Text(L10n.settings_appearance)
            } footer: {
                Text(L10n.settings_highContrastFooter)
            }
            Section(L10n.settings_habits) {
                Text(L10n.settingsRemindAdvance(settings.values[.remindAdvanceMinutes] ?? "-"))
                Text(L10n.settingsSnooze(settings.values[.snoozeMinutes] ?? "-"))
                Text(L10n.settingsQuietHours(settings.values[.quietHoursStart] ?? "-",
                                  settings.values[.quietHoursEnd] ?? "-"))
            }
            Section(L10n.hub_healthRecords) {
                NavigationLink(L10n.member_title) {
                    MemberManagementView()
                }
                .accessibilityIdentifier("SP-25.settings.members")
                NavigationLink(L10n.inventory_title) {
                    InventoryHubView()
                }
                .accessibilityIdentifier("SP-25.settings.inventory")
                NavigationLink(L10n.emergency_title) {
                    EmergencyCardHubView()
                }
                .accessibilityIdentifier("SP-25.settings.emergencyCard")
                NavigationLink(L10n.immunization_title) {
                    ImmunizationHubView()
                }
                .accessibilityIdentifier("SP-25.settings.immunization")
                NavigationLink(L10n.claim_title) {
                    ClaimHubView()
                }
                .accessibilityIdentifier("SP-25.settings.claim")
                NavigationLink(L10n.fr24_title) {
                    SentStatusHubView()
                }
                .accessibilityIdentifier("SP-25.settings.sentStatus")
                NavigationLink(L10n.hub_guidelines) {
                    GuidelineHubView()
                }
                .accessibilityIdentifier("SP-25.settings.guidelines")
            }
            Section(L10n.settings_pro) {
                NavigationLink(L10n.proOutput_title) {
                    ProOutputHubView()
                }
                .accessibilityIdentifier("SP-25.settings.proOutputs")
                NavigationLink(L10n.settings_proUpgrade) {
                    PaywallView()
                }
                .accessibilityIdentifier("SP-25.settings.pro")
            }
            Section(L10n.settings_privacy) {
                NavigationLink(L10n.settings_audit) {
                    AuditLogView()
                }
                .accessibilityIdentifier("SP-25.settings.audit")
                Button(L10n.settings_restoreDefaults) {
                    Task { try await settings.restoreDefaults() }
                }
            }
            Section(L10n.settings_about) {
                NavigationLink(L10n.settings_help) {
                    HelpAboutView()
                }
                .accessibilityIdentifier("SP-25.settings.help")
                Text(L10n.settings_disclaimer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("我的")
        .task { await settings.load() }
    }

    /// FR14.1 分目的授权开关（M1c 已落键的两项；其余随功能模块上线逐步接入）
    private var authKeys: [AppSettingKey] {
        [.careModeEnable, .voiceEntryVisible]
    }

    private func binding(for key: AppSettingKey) -> Binding<Bool> {
        Binding(
            get: {
                switch key {
                // 运行时真源 = AppState.careMode（驱动 CareModeMetrics/触点放大等）；
                // DB 键为镜像。读回实际状态，避免开关显示与行为脱节（split-brain 修复）
                case .careModeEnable: return toggles[key] ?? app.careMode
                default: return toggles[key] ?? (settings.values[key] == "true")
                }
            },
            set: { newValue in
                toggles[key] = newValue
                if key == .careModeEnable { app.careMode = newValue }   // 双写运行时真源
                Task { try await settings.set(newValue ? "true" : "false", for: key) }
            })
    }

    /// FR14.4 主题绑定（tech-spec §5.28.1：值存 DB app_settings，@Observable 即时生效）
    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: {
                AppTheme(rawValue: settings.values[.appearance]
                         ?? AppSettingKey.appearance.defaultValue) ?? .system
            },
            set: { theme in
                Task { try await settings.set(theme.rawValue, for: .appearance) }
            })
    }

    private func label(for key: AppSettingKey) -> String {
        switch key {
        case .careModeEnable: return L10n.settings_careMode
        case .voiceEntryVisible: return L10n.settings_voiceEntry
        case .highContrastEnabled: return L10n.settings_highContrast
        default: return key.rawValue
        }
    }
}

/// 审计记录页（FR14.2）：append-only 事实列表
struct AuditLogView: View {
    @Environment(AppSettingsStore.self) private var settings
    var body: some View {
        List(settings.auditEntries, id: \.id) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.action).font(.subheadline)
                Text("\(entry.entityType) · \(entry.at.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("审计记录")
        .task { await settings.loadAudit() }
    }
}
