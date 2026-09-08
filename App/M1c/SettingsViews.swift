import SwiftUI
import Domain

/// F14 设置中心（SP 系列 M1c 切片）：分目的授权九开关（FR14.1 独立开关语义）、
/// 常用习惯（FR14.7）、审计与关于入口。
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppEntitlementStore.self) private var entitlements
    @State private var toggles: [AppSettingKey: Bool] = [:]

    var body: some View {
        Form {
            // mock 对齐项：离线模式副标题（数据透明信任资产）
            Section {
                Label(L10n.settings_offlineNote, systemImage: "checkmark.shield")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("SP-25.settings.offlineNote")
            }
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
                // FR14.5 显示语言（§5.12.2）+ FR17.15/16 语音语言（§5.12.3）
                NavigationLink {
                    LanguageSettingsView()
                } label: {
                    LabeledContent(L10n.languageTitle, value: currentLanguageName)
                }
                .accessibilityIdentifier("SP-25.setting.language")
                NavigationLink {
                    VoiceLanguageSettingsView()
                } label: {
                    LabeledContent(L10n.voiceLangTitle, value: app.voiceOutputLocale)
                }
                .accessibilityIdentifier("SP-25.setting.voiceLanguage")
            } header: {
                Text(L10n.settings_appearance)
            } footer: {
                Text(L10n.settings_highContrastFooter)
            }
            // §5.12 安全（自动锁定）组（V3.72 接线：FR1.4 宽限 0/15/60 秒）
            Section(L10n.settings_gateGrace) {
                Picker(selection: Binding(
                    get: { settings.values[.gateGraceSeconds] ?? "0" },
                    set: { v in Task { await settings.set(v, for: .gateGraceSeconds) } }
                )) {
                    Text(L10n.settings_grace0).tag("0")
                    Text(L10n.settings_grace15).tag("15")
                    Text(L10n.settings_grace60).tag("60")
                } label: {
                    Text(L10n.settings_autoLock)
                }
            }
            // §5.12 通知中心与提醒偏好组（V3.72 补：此前设置中心无通知中心入口，
            // 首页铃铛是唯一路径；提醒触达设置页亦缺失）
            Section(L10n.ncTitle) {
                NavigationLink(L10n.ncTitle) {
                    NotificationCenterView()
                }
                .accessibilityIdentifier("SP-26.notificationCenter")
                NavigationLink(L10n.remchTitle) {
                    ReminderChannelSettingsView()
                }
                .accessibilityIdentifier("SP-26.remch.entry")
            }
            Section(L10n.settings_habits) {
                // FR14.7 常用习惯：可编辑偏好中心（含「仅新建/全局生效」标签）
                NavigationLink(L10n.settings_habits) {
                    PreferencesView()
                }
                .accessibilityIdentifier("SP-26.preferences")
                // FR14.3 数据生命周期页（四级删除语义 + 影响清单）
                NavigationLink(L10n.settings_dataLifecycle) {
                    DataLifecycleView()
                }
                .accessibilityIdentifier("FR14.3.dataLifecycle")
                // FR13.1/13.2 导出向导
                NavigationLink(L10n.exportWizardTitle) {
                    ExportWizardView()
                }
                .accessibilityIdentifier("SP-22.export.entry")
                NavigationLink(L10n.backupTitle) {
                    BackupView()
                }
                .accessibilityIdentifier("SP-23.backup.entry")
            }
            Section(L10n.hub_healthRecords) {
                // mock 对齐项：语音指导模式入口（FR17.11 档案完善/修改，可语音可手输）
                NavigationLink(value: AppRoute.voiceGuideProfile) {
                    Label(L10n.voiceguide_profileTitle, systemImage: "waveform.and.mic")
                }
                .accessibilityIdentifier("SP-25.settings.voiceGuide")
                NavigationLink(L10n.member_title) {
                    MemberManagementView()
                }
                .accessibilityIdentifier("SP-25.settings.members")
                // F23 过敏与不良反应（SP-50 入口）
                NavigationLink(L10n.allergyTitle) {
                    AllergyListView()
                }
                .accessibilityIdentifier("SP-25.settings.allergy")
                NavigationLink(L10n.inventory_title) {
                    InventoryHubView()
                }
                .accessibilityIdentifier("SP-25.settings.inventory")
                NavigationLink(L10n.emergency_title) {
                    EmergencyCardHubView()
                }
                .accessibilityIdentifier("SP-25.settings.emergencyCard")
                // 评审修正 H15：走类型安全路由（注册表覆盖 SP-54，通知深链可直达）
                NavigationLink(value: AppRoute.immunizationList) {
                    Text(L10n.immunization_title)
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
                NavigationLink(L10n.proOutputTitle) {
                    ProOutputHubView()
                }
                .accessibilityIdentifier("SP-25.settings.proOutputs")
                NavigationLink(L10n.settings_proUpgrade) {
                    PaywallView()
                }
                .accessibilityIdentifier("SP-25.settings.pro")
                // comercial §3 免费体验保护：「恢复购买」常驻设置中心
                Button(L10n.pay_restore) {
                    Task { await entitlements.restore() }
                }
                .accessibilityIdentifier("SP-25.settings.restorePurchases")
            }
            Section(L10n.settings_privacy) {
                // FR14.1 分目的授权面板入口
                NavigationLink(L10n.privacyAuthTitle) {
                    PrivacyAuthorizationView()
                }
                .accessibilityIdentifier("SP-25.settings.privacyAuth")
                NavigationLink(L10n.settings_audit) {
                    AuditLogView()
                }
                .accessibilityIdentifier("SP-25.settings.audit")
                Button(L10n.settings_restoreDefaults) {
                    // 审查修复：恢复默认后必须清本地 toggles 影子——get 优先
                    // 读 toggles，不清则开关显示仍停留在用户改过的旧值
                    // （隐私开关虚显示），离开重进才自愈。
                    toggles = [:]
                    Task { await settings.restoreDefaults() }
                }
            }
            Section(L10n.settings_about) {
                NavigationLink(L10n.settings_help) {
                    HelpRootView()
                }
                .accessibilityIdentifier("SP-25.settings.help")
                Text(L10n.settings_disclaimer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.navMe)
        .task { await settings.load() }
    }

    /// FR14.1 分目的授权开关。
    /// 审查修复（诚实性，FR14.7）：七项授权开关（OCR/AI/家庭/分享/云备份/
    /// 匿名改进/语音速记）此前全仓零消费点——「可调但无效果」的开关违反
    /// FR14.7 与 BR-010「撤回即时生效」承诺，与 PreferencesViews 同纪律移除，
    /// 接线后恢复（撤回立即生效的实现需消费端在权限检查点读取本键）。
    private var authKeys: [AppSettingKey] {
        [.authHealthRead, .careModeEnable, .voiceEntryVisible]
    }

    private func binding(for key: AppSettingKey) -> Binding<Bool> {
        Binding(
            get: {
                switch key {
                // 运行时真源 = AppState.careMode（驱动 CareModeMetrics/触点放大等）；
                // DB 键为镜像。读回实际状态，避免开关显示与行为脱节（split-brain 修复）
                case .careModeEnable: return toggles[key] ?? app.careMode
                // 审查修复（口径统一）：布尔读一律与键默认值比较——
                // `!= "false"` 与 `== "true"` 在 values 未装载（nil）时对
                // 同一键显示相反状态（本页开/外观页关）；统一
                // `(values[key] ?? defaultValue) == "true"` 装载前后一致。
                default: return toggles[key] ?? ((settings.values[key] ?? key.defaultValue) == "true")
                }
            },
            set: { newValue in
                toggles[key] = newValue
                if key == .careModeEnable { app.careMode = newValue }   // 双写运行时真源
                Task { await settings.set(newValue ? "true" : "false", for: key) }
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
                Task { await settings.set(theme.rawValue, for: .appearance) }
            })
    }

    private var currentLanguageName: String {
        L10n.supportedDisplayLanguages
            .first { $0.code == L10n.bundleLanguage }?.nativeName ?? L10n.bundleLanguage
    }

    private func label(for key: AppSettingKey) -> String {
        switch key {
        case .careModeEnable: return L10n.settings_careMode
        case .voiceEntryVisible: return L10n.settings_voiceEntry
        case .highContrastEnabled: return L10n.settings_highContrast
        case .authOcr: return L10n.authOcrLabel
        case .authAI: return L10n.authAILabel
        case .authFamilyAccess: return L10n.authFamilyLabel
        case .authSharing: return L10n.authSharingLabel
        case .authCloudBackup: return L10n.authCloudBackupLabel
        case .authAnonymizedImprovement: return L10n.authAnonymizedLabel
        case .authHealthRead: return L10n.authHealthLabel
        case .authVoiceDictation: return L10n.authVoiceDictationLabel
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
        .navigationTitle(L10n.settings_audit)
        .task { await settings.loadAudit() }
    }
}
