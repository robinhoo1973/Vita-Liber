import SwiftUI
import Domain
import Perception

/// F14 设置中心（SP-25）：个人资料 / 通知与提醒 / 外观与语言 / 数据与存储 /
/// 隐私与安全 / Pro 与订阅 / 关于与帮助七组（V4.70 业主收口）。
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
                // 2026-10-24 业主：紧急信息卡是急救场景的第一入口——置于头像
                // 下方作为一级卡片（本页直达 F15 展示/配置，不改变急救卡本身
                // 的制作与展示）。联系人与常用成员同组，图标一视同仁。
                Section {
                    NavigationLink {
                        EmergencyCardHubView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "cross.case.fill")
                                .font(.title3)
                                .foregroundStyle(Color("brand-primary", bundle: .main))
                                .frame(width: 40, height: 40)
                                .background(Color("brand-primary", bundle: .main).opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.emergency_title)
                                    .font(.subheadline.weight(.semibold))
                                Text(L10n.profileEmergencyCardHint)
                                    .font(.caption)
                                    .foregroundStyle(Color("text-secondary", bundle: .main))
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("SP-25.setting.emergencyCard")
                }
                Section {
                    HStack(spacing: 0) {
                        statCell("\(app.members.count)", L10n.profileStatMembers, icon: "person.2.fill")
                        Divider().frame(height: 34)
                        statCell("\(docs.documents.count)", L10n.profileStatRecords, icon: "doc.text.fill")
                        Divider().frame(height: 34)
                        statCell("\(chatCount)", L10n.profileStatChats, icon: "bubble.left.and.bubble.right.fill")
                    }
                    .frame(maxWidth: .infinity)
                }
                Section(L10n.profilePersonal) {
                    NavigationLink {
                        AssistantAppearanceView()
                    } label: {
                        Label(L10n.profileAssistantRow, systemImage: "sparkles")
                    }
                    NavigationLink(value: AppRoute.healthHistoryHub) {
                        Label(L10n.hub_healthRecords, systemImage: "heart.text.square")
                    }
                    .accessibilityIdentifier("SP-25.setting.healthHistory")
                    // 2026-10-24 业主：紧急联系人自医疗档案抽离，落到个人资料
                    // 「常用成员」之前；急救卡与 SOS 求助页读取同一数据源。
                    NavigationLink {
                        EmergencyContactListView()
                    } label: {
                        Label(L10n.emergencySectionContacts,
                              systemImage: "person.crop.circle.badge.exclamationmark")
                    }
                    .accessibilityIdentifier("SP-25.setting.emergencyContacts")
                    NavigationLink {
                        MemberManagementView()
                    } label: {
                        LabeledContent {
                            Text("\(app.members.count)")
                        } label: {
                            Label(L10n.profileMembersRow, systemImage: "person.2")
                        }
                    }
                    // 保留既有 XCUITest 锚点：入口从根级「健康记录」区块迁到个人资料后，
                    // MemberViewsPresentationUITests 仍按此标识定位。
                    .accessibilityIdentifier("SP-25.settings.members")
                }
                // §5.12 通知中心与提醒偏好组（V3.72 补：此前设置中心无通知中心入口，
                // 首页铃铛是唯一路径；提醒触达设置页亦缺失）
                Section(L10n.settings_notificationsGroup) {
                    NavigationLink {
                        NotificationCenterView()
                    } label: {
                        Label(L10n.ncTitle, systemImage: "bell")
                    }
                    .accessibilityIdentifier("SP-26.notificationCenter")
                    NavigationLink {
                        ReminderChannelSettingsView()
                    } label: {
                        Label(L10n.remchTitle, systemImage: "bell.badge")
                    }
                    .accessibilityIdentifier("SP-26.remch.entry")
                }
                // FR14.4 外观与主题（§5.12.1：三段选择器 + 高对比度/关怀模式；位置对齐 mock 我的页）
                Section {
                    ThemeSegmentedPicker(selection: themeBinding)
                    Toggle(isOn: binding(for: .highContrastEnabled)) {
                        Label(L10n.settings_highContrast, systemImage: "circle.lefthalf.filled")
                    }
                    .accessibilityIdentifier("SP-25.setting.highContrast")
                    // 2026-10-23 业主：关怀模式并入外观与主题，不再放在授权区。
                    Toggle(isOn: binding(for: .careModeEnable)) {
                        Label(L10n.settings_careMode, systemImage: "figure.and.child.holdinghands")
                    }
                    .accessibilityIdentifier("SP-25.setting.careModeEnable")
                    // 2026-10-23 业主：原「安全」组改名「自动锁定」并并入本组。
                    Picker(selection: Binding(
                        get: { SettingsRules.resolved(settings.values[.gateGraceSeconds], key: .gateGraceSeconds) },
                        set: { v in Task { await settings.set(v, for: .gateGraceSeconds) } }
                    )) {
                        ForEach(SettingsRules.gateGraceSecondsLegalValues.map(Int.init), id: \.self) { value in
                            Text(L10n.settings_graceSeconds(value)).tag("\(value)")
                        }
                    } label: {
                        Label(L10n.settings_autoLock, systemImage: "lock")
                    }
                    .accessibilityIdentifier("SP-25.setting.gateGraceSeconds")
                    // FR14.5 显示语言（§5.12.2）+ FR17.15/16 语音语言（§5.12.3）
                    NavigationLink {
                        LanguageSettingsView()
                    } label: {
                        LabeledContent {
                            Text(currentLanguageName)
                        } label: {
                            Label(L10n.languageTitle, systemImage: "globe")
                        }
                    }
                    .accessibilityIdentifier("SP-25.setting.language")
                    NavigationLink {
                        VoiceLanguageSettingsView()
                    } label: {
                        // V4.13 呈现评审：值显示语言名摘要（主语言 +N），
                        // 不再直出 locale 代码（如 zh-CN）
                        LabeledContent {
                            Text(currentVoiceLanguages)
                        } label: {
                            Label(L10n.voiceLangTitle, systemImage: "waveform")
                        }
                    }
                    .accessibilityIdentifier("SP-25.setting.voiceLanguage")
                    // FR14.7 常用习惯：显示格式与朗读语速并入「外观与语言」。
                    NavigationLink {
                        PreferencesView()
                    } label: {
                        Label(L10n.settings_habits, systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("SP-26.preferences")
                } header: {
                    Text(L10n.settings_appearance)
                } footer: {
                    // 2026-10-03 信息架构评审（方案 C）：ThemeSettingsView 页并入主面后，
                    // 关怀模式强制叠加高对比度的「明示当前生效层」注记随迁此处（原页 footer）。
                    Text(app.careMode ? L10n.settings_highContrastForced
                                      : L10n.settings_highContrastFooter)
                }
                // 2026-10-24 业主：数据导入/导出/备份/资源/删除收敛为「数据与存储」。
                Section {
                    NavigationLink(value: AppRoute.deviceConnection) {
                        Label(L10n.healthImportSettingsTitle, systemImage: "heart.text.square")
                    }
                    .accessibilityIdentifier("SP-25.settings.appleHealth")
                    // 医疗数据入口紧随 Apple 健康（2026-10-27 业主反馈：医疗数据需有
                    // 下载/更新入口；ui-ux §5.12.4 原定位置即 Apple Health 之后）。
                    NavigationLink(value: AppRoute.resourceManagement) {
                        Label(L10n.resourceManagementTitle, systemImage: "shippingbox")
                    }
                    .accessibilityIdentifier("SP-64.settings.resources")
                    // 同步间隔已并入 Apple 健康数据二级页（2026-10-23 业主）。
                    // FR13.1/13.2 导出向导
                    NavigationLink {
                        ExportWizardView()
                    } label: {
                        Label(L10n.exportWizardTitle, systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("SP-22.export.entry")
                    NavigationLink {
                        BackupView()
                    } label: {
                        Label(L10n.backupTitle, systemImage: "externaldrive")
                    }
                    .accessibilityIdentifier("SP-23.backup.entry")
                    // SP-64 统一资源管理页入口（2026-09-27 业主定案；2026-10-27 上移至
                    // Apple 健康之后）
                    // FR14.3 数据生命周期页（三级删除语义 + 影响清单）——删除入口置底。
                    NavigationLink {
                        DataLifecycleView()
                    } label: {
                        Label(L10n.settings_dataLifecycle, systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("FR14.3.dataLifecycle")
                } header: {
                    Text(L10n.settings_dataAndResources)
                }
                Section(L10n.settings_privacy) {
                    // FR14.1 分目的授权面板入口
                    NavigationLink {
                        PrivacyAuthorizationView()
                    } label: {
                        Label(L10n.privacyAuthTitle, systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("SP-25.settings.privacyAuth")
                    // 2026-10-22 业主：发送状态归入隐私与安全，不再放在健康档案。
                    NavigationLink {
                        SentStatusHubView()
                    } label: {
                        Label(L10n.fr24_title, systemImage: "paperplane")
                    }
                    .accessibilityIdentifier("SP-25.settings.sentStatus")
                    NavigationLink {
                        AuditLogView()
                    } label: {
                        Label(L10n.settings_audit, systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("SP-25.settings.audit")
                }
                Section(L10n.settings_pro) {
                    NavigationLink {
                        ProOutputHubView()
                    } label: {
                        Label(L10n.proOutputTitle, systemImage: "doc.richtext")
                    }
                    .accessibilityIdentifier("SP-25.settings.proOutputs")
                    NavigationLink {
                        PaywallView()
                    } label: {
                        Label(L10n.settings_proUpgrade, systemImage: "star.circle")
                    }
                    .accessibilityIdentifier("SP-25.settings.pro")
                    // comercial §3 免费体验保护：「恢复购买」常驻设置中心
                    Button {
                        Task { await entitlements.restore() }
                    } label: {
                        Label(L10n.pay_restore, systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("SP-25.settings.restorePurchases")
                }
                Section(L10n.settings_about) {
                    NavigationLink {
                        HelpRootView()
                    } label: {
                        Label(L10n.settings_help, systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("SP-25.settings.help")
                    // 2026-10-22 业主：参考范围/信源库从健康档案移到关于。
                    NavigationLink {
                        GuidelineHubView()
                    } label: {
                        Label(L10n.hub_guidelines, systemImage: "book")
                    }
                    .accessibilityIdentifier("SP-25.settings.guidelines")
                    // FR22.8 版本与法律（自帮助中心上移；帮助中心不再重复入口）。
                    NavigationLink(value: AppRoute.termsAndPrivacy) {
                        Label(L10n.helpAboutLegal, systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("SP-25.settings.aboutLegal")
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

    private func statCell(_ value: String, _ title: String, icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Color("brand-primary", bundle: .main))
                .accessibilityHidden(true)
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
