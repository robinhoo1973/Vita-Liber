import SwiftUI
import Domain
import Perception

/// F14 设置中心（SP 系列 M1c 切片）：分目的授权九开关（FR14.1 独立开关语义）、
/// 常用习惯（FR14.7）、审计与关于入口。
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppEntitlementStore.self) private var entitlements
    @Environment(DocumentsState.self) private var docs
    @Environment(ChatHistoryState.self) private var chatHistory
    @State private var toggles: [AppSettingKey: Bool] = [:]
    @State private var chatCount = 0

    var body: some View {
        WithPerceptionTracking {
            Form {
                // User Profile 头部（2026-10-19 设计稿 04）：头像/昵称 + 本机徽标 + 概览。
                Section {
                    NavigationLink {
                        AvatarSettingsView()
                    } label: {
                        VStack(spacing: 8) {
                            AvatarView(size: 84)
                            Text(userDisplayName)
                                .font(.title3.weight(.semibold))
                            Text(L10n.profileLocalBadge)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("SP-25.setting.avatar")
                }
                Section {
                    HStack(spacing: 0) {
                        statCell("\(app.members.count)", L10n.profileStatMembers)
                        Divider().frame(height: 34)
                        statCell("\(docs.documents.count)", L10n.profileStatRecords)
                        Divider().frame(height: 34)
                        statCell("\(chatCount)", L10n.profileStatChats)
                    }
                    .frame(maxWidth: .infinity)
                }
                Section(L10n.profilePersonal) {
                    NavigationLink {
                        AvatarSettingsView()
                    } label: {
                        Label(L10n.profileAvatarRow, systemImage: "person.crop.circle")
                    }
                    NavigationLink {
                        AssistantAppearanceView()
                    } label: {
                        Label(L10n.profileAssistantRow, systemImage: "sparkles")
                    }
                    NavigationLink(value: AppRoute.healthHistoryHub) {
                        Label(L10n.hub_healthRecords, systemImage: "heart.text.square")
                    }
                    .accessibilityIdentifier("SP-25.setting.healthHistory")
                    NavigationLink {
                        MemberManagementView()
                    } label: {
                        LabeledContent(L10n.profileMembersRow, value: "\(app.members.count)")
                    }
                    // 保留既有 XCUITest 锚点：入口从根级「健康记录」区块迁到个人资料后，
                    // MemberViewsPresentationUITests 仍按此标识定位。
                    .accessibilityIdentifier("SP-25.settings.members")
                }
                // FR14.4 外观与主题（§5.12.1：三段选择器 + 高对比度/关怀模式；位置对齐 mock 我的页）
                Section {
                    ThemeSegmentedPicker(selection: themeBinding)
                    Toggle(isOn: binding(for: .highContrastEnabled)) {
                        Text(L10n.settings_highContrast)
                    }
                    .accessibilityIdentifier("SP-25.setting.highContrast")
                    // 2026-10-23 业主：关怀模式并入外观与主题，不再放在授权区。
                    Toggle(isOn: binding(for: .careModeEnable)) {
                        Text(L10n.settings_careMode)
                    }
                    .accessibilityIdentifier("SP-25.setting.careModeEnable")
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
                        // V4.13 呈现评审：值显示语言名摘要（主语言 +N），
                        // 不再直出 locale 代码（如 zh-CN）
                        LabeledContent(L10n.voiceLangTitle, value: currentVoiceLanguages)
                    }
                    .accessibilityIdentifier("SP-25.setting.voiceLanguage")
                } header: {
                    Text(L10n.settings_appearance)
                } footer: {
                    // 2026-10-03 信息架构评审（方案 C）：ThemeSettingsView 页并入主面后，
                    // 关怀模式强制叠加高对比度的「明示当前生效层」注记随迁此处（原页 footer）。
                    Text(app.careMode ? L10n.settings_highContrastForced
                                      : L10n.settings_highContrastFooter)
                }
                // §5.12 安全（自动锁定）组（FR1.4 宽限 5/15/60 秒；选项由
                // Domain 合法集单一事实源生成——业主 2026-09-19：最低宽限 5 秒，
                // 0 档（立即锁）与系统认证浮层的 transient inactive 叠加形成
                // 人脸识别循环，退出合法域）
                Section(L10n.settings_gateGrace) {
                    Picker(selection: Binding(
                        get: { SettingsRules.resolved(settings.values[.gateGraceSeconds], key: .gateGraceSeconds) },
                        set: { v in Task { await settings.set(v, for: .gateGraceSeconds) } }
                    )) {
                        ForEach(SettingsRules.gateGraceSecondsLegalValues.map(Int.init), id: \.self) { value in
                            Text(L10n.settings_graceSeconds(value)).tag("\(value)")
                        }
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
                // 2026-10-03 信息架构评审（方案 C，ui-ux V4.12）：原 12 入口「健康记录」
                // 大区拆分——「数据与资源」= 数据导入/资源下载同域聚合；其余档案与记录
                // 管理入口归「健康记录」。入口集合不变，仅分组。
                Section {
                    NavigationLink(value: AppRoute.deviceConnection) {
                        Label(L10n.healthImportSettingsTitle, systemImage: "heart.text.square")
                    }
                    .accessibilityIdentifier("SP-25.settings.appleHealth")
                    // 同步间隔已并入 Apple 健康数据二级页（2026-10-23 业主）。
                    // SP-64 统一资源管理页入口（2026-09-27 业主定案）
                    NavigationLink(value: AppRoute.resourceManagement) {
                        Label(L10n.resourceManagementTitle, systemImage: "shippingbox")
                    }
                    .accessibilityIdentifier("SP-64.settings.resources")
                } header: {
                    Text(L10n.settings_dataAndResources)
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
                    // 2026-10-22 业主：发送状态归入隐私与数据，不再放在健康档案。
                    NavigationLink(L10n.fr24_title) {
                        SentStatusHubView()
                    }
                    .accessibilityIdentifier("SP-25.settings.sentStatus")
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
                    // 2026-10-22 业主：参考范围/信源库从健康档案移到关于。
                    NavigationLink(L10n.hub_guidelines) {
                        GuidelineHubView()
                    }
                    .accessibilityIdentifier("SP-25.settings.guidelines")
                    Text(L10n.settings_disclaimer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // V4.13 呈现评审：离线信任声明自页首独立段降级至此（页尾轻行）
                    Label(L10n.settings_offlineNote, systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("SP-25.settings.offlineNote")
                }
            }
            .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出（V4.13 补齐）
            // 2026-10-04 业主反馈（tab 页顶部留空过大）：同 HomeView 先例
            .contentMarginsCompat(.top, 0, for: .scrollContent)
            .listSectionSpacingCompat(.compact)
            .tintedCanvas()   // 与全部设置子页视觉基底统一（此前本页 Form 裸白）
            .navigationTitle(L10n.navMe)
            .navigationBarTitleDisplayMode(.inline)   // 2026-10-04 业主反馈：tab 根统一 inline（同 HomeView 先例）
            .task {
                await settings.load()
                chatCount = await chatHistory.count(patientId: app.currentPatientId)
            }
        }
    }

    /// FR14.1 分目的授权开关。
    /// 审查修复（诚实性，FR14.7）：七项授权开关（OCR/AI/家庭/分享/云备份/
    /// 匿名改进/语音速记）此前全仓零消费点——「可调但无效果」的开关违反
    /// FR14.7 与 BR-010「撤回即时生效」承诺，与 PreferencesViews 同纪律移除，
    /// 接线后恢复（撤回立即生效的实现需消费端在权限检查点读取本键）。
    private func binding(for key: AppSettingKey) -> Binding<Bool> {
        Binding(
            get: {
                switch key {
                // 运行时真源 = AppState.careMode（驱动 CareModeMetrics/触点放大等）；
                // DB 键为镜像。读回实际状态，避免开关显示与行为脱节（split-brain 修复）
                case .careModeEnable: return toggles[key] ?? app.careMode
                // 审查修复（口径统一）：布尔读一律与键默认值比较——
                // `!= "false"` 与 `== "true"` 在 values 未装载（nil）时对
                // 同一键显示相反状态（本页开/外观页关）；统一口径收敛
                // AppSettingsBindings.bool（装载前后一致，三处绑定同源）。
                default: return toggles[key] ?? AppSettingsBindings.bool(settings, for: key)
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
        AppSettingsBindings.theme(settings)
    }

    private var currentLanguageName: String {
        L10n.supportedDisplayLanguages
            .first { $0.code == L10n.bundleLanguage }?.nativeName ?? L10n.bundleLanguage
    }

    /// FR17.15 语音语言行值摘要（V4.13 呈现评审）：「主语言原生名」或「主语言 +N」——
    /// 行值必须人类可读，不直出 locale 代码。原生名映射走 Domain 两语言单一事实源。
    private var currentVoiceLanguages: String {
        let locales = SettingsRules.voiceLocales(settings.values[.voiceInputLanguages])
        guard let primary = locales.first else { return L10n.voiceLangTitle }
        let name = EngineCapabilityProfile.twoLanguages.first {
            TranscriptionLocale.normalizedIdentifier($0.locale) == TranscriptionLocale.normalizedIdentifier(primary)
        }?.nativeName ?? primary
        return locales.count > 1 ? "\(name) +\(locales.count - 1)" : name
    }

    private func statCell(_ value: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold))
                .foregroundStyle(Color("brand-primary", bundle: .main))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var userDisplayName: String {
        app.owner?.displayName ?? app.members.first?.displayName ?? L10n.help_appName
    }

}

/// 审计记录页（FR14.2）：append-only 事实列表
struct AuditLogView: View {
    @Environment(AppSettingsStore.self) private var settings
    /// V4.13 呈现评审：装载完成前显示加载态（此前首帧直接渲染列表）；
    /// 空列表显示空态说明（此前空页无任何解释）。
    @State private var loaded = false
    var body: some View {
        WithPerceptionTracking {
            Group {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding()
                } else if settings.auditEntries.isEmpty {
                    Text(L10n.settings_auditEmpty)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding()
                } else {
                    List(settings.auditEntries, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.action).font(.subheadline)
                            Text("\(entry.entityType) · \(entry.at.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .scrollContentBackground(.hidden)   // ui-ux §3.0：渐变画布透出（V4.13 补齐）
                    .tintedCanvas()
                }
            }
            .navigationTitle(L10n.settings_audit)
            .task {
                await settings.loadAudit()
                loaded = true
            }
        }
    }
}
