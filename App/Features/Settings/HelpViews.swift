import SwiftUI
import Domain
import Protocols
import UserNotifications
import AVFoundation
import LocalAuthentication
import Perception

// MARK: - FR22.1 帮助中心根视图

/// 诊断状态：文案与色调同源。此前用 `status.contains(L10n.helpStatusAuthorized)`
/// 推断颜色——任何让其他状态文案包含「已授权/正常」的改词都会把临时授权/
/// 未知状态染成绿色（诊断页谎报授权）。
private enum DiagnosticStatus: Equatable {
    case checking
    case authorized
    case denied
    case provisional
    case notRequested
    case unknown
    case requiresDevice
    case normal
    case corrupt

    var text: String {
        switch self {
        case .checking: return L10n.helpStatusChecking
        case .authorized: return L10n.helpStatusAuthorized
        case .denied: return L10n.helpStatusDenied
        case .provisional: return L10n.helpStatusProvisional
        case .notRequested: return L10n.helpStatusNotRequested
        case .unknown: return L10n.helpStatusUnknown
        case .requiresDevice: return L10n.helpFaceIDRequiresDevice
        case .normal: return L10n.helpDataNormal
        case .corrupt: return L10n.helpDataCorrupt
        }
    }

    /// 绿色仅限明确的「已授权 / 正常」。
    var isPositive: Bool { self == .authorized || self == .normal }
}

/// 系统权限状态 → 诊断状态（权限诊断与提醒诊断共用口径，两处六分支复制收敛）。
private enum AuthorizationStatusLabel {
    /// UNAuthorizationStatus → 状态
    static func notification(_ status: UNAuthorizationStatus) -> DiagnosticStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .provisional, .ephemeral: return .provisional
        case .notDetermined: return .notRequested
        @unknown default: return .unknown
        }
    }

    /// AVAuthorizationStatus（相机/麦克风同口径）→ 状态
    static func capture(_ status: AVAuthorizationStatus) -> DiagnosticStatus {
        switch status {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notRequested
        @unknown default: return .unknown
        }
    }
}

/// F22 帮助中心入口：按功能提供诊断工具、教程、FAQ 和关于页。
struct HelpRootView: View {
    var body: some View {
        WithPerceptionTracking {
            Form {
                // §5.20 七类教程入口（V3.72 补：此前只有三项诊断 + 关于页）
                Section(L10n.helpTutorialTitle) {
                    ForEach(helpTopics) { topic in
                        NavigationLink {
                            HelpTopicView(title: topic.title, bullets: topic.bullets,
                                          isVoiceTopic: topic.id == HelpTopic.voiceID)
                        } label: {
                            Label(topic.title, systemImage: topic.icon)
                        }
                    }
                }
                Section {
                    // 评审修正 H15：走类型安全路由（注册表覆盖 SP-43）
                    NavigationLink(value: AppRoute.helpPermissionDiagnostics) {
                        Label(L10n.helpDiagPermission, systemImage: "lock.shield")
                    }
                    .accessibilityIdentifier("FR22.2.permissionDiagnostics")

                    // 评审修正 H15：走类型安全路由（注册表覆盖 SP-44）。
                    // 用实心铃铛与上方教程区的「提醒与通知」空心铃铛区分；
                    // `bell.badge.exclamationmark` 不是有效 SF Symbol。
                    NavigationLink(value: AppRoute.helpReminderDiagnostics) {
                        Label(L10n.helpDiagReminder, systemImage: "bell.badge.fill")
                    }
                    .accessibilityIdentifier("FR22.3.reminderDiagnostics")

                    // §5.45：SP-45 补登记为 value 路由（此前是闭包目的地，
                    // 无法深链/跨启动恢复，关怀模式常驻返回还会跨级弹栈）。
                    NavigationLink(value: AppRoute.helpDataHealth) {
                        Label(L10n.helpDiagDataHealth, systemImage: "externaldrive.badge.checkmark")
                    }
                    .accessibilityIdentifier("FR22.4.dataHealth")
                } header: {
                    Text(L10n.helpDiagSystem)
                } footer: {
                    Text(L10n.helpDiagSystemHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    // 2026-10-03 信息架构评审（方案 C）：反馈入口接线（SP-46 已注册
                    // 但此前零入口的死路由）——反馈是隐私优先产品的信任资产，落帮助中心。
                    NavigationLink(value: AppRoute.feedbackReport) {
                        Label(L10n.feedbackTitle, systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .accessibilityIdentifier("FR22.9.feedback")
                }
            }
            // 审查修复（死控件清除）：.searchable(.constant("")) 渲染永久失效的
            // 搜索条（绑定常量、零搜索逻辑）——删除。
                        .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出（V4.13 补齐）
            .tintedCanvas()
.navigationTitle(L10n.helpCenterTitle)
        }
    }

    /// 教程条目用稳定 id 作身份/行为条件——此前以本地化标题作 ForEach id
    /// 且以 `title == L10n.helpTopicVoice` 决定是否显示朗读按钮：改词条文案
    /// 即丢朗读入口，标题撞车即触发重复 id。
    private struct HelpTopic: Identifiable {
        static let voiceID = "voice"
        let id: String
        let title: String
        let icon: String
        let bullets: [String]
    }

    private var helpTopics: [HelpTopic] {
        [
            HelpTopic(id: "gettingStarted", title: L10n.helpTopicGettingStarted,
                      icon: "person.crop.circle.badge.plus",
                      bullets: [L10n.helpGettingStarted1, L10n.helpGettingStarted2]),
            HelpTopic(id: "importOcr", title: L10n.helpTopicImportOcr,
                      icon: "doc.viewfinder",
                      bullets: [L10n.helpImportOcr1, L10n.helpImportOcr2]),
            HelpTopic(id: "reminders", title: L10n.helpTopicReminders,
                      icon: "bell.badge",
                      bullets: [L10n.helpReminders1, L10n.helpReminders2]),
            HelpTopic(id: "privacy", title: L10n.helpTopicPrivacy,
                      icon: "lock.shield",
                      bullets: [L10n.helpPrivacy1, L10n.helpPrivacy2]),
            HelpTopic(id: "care", title: L10n.helpTopicCare,
                      icon: "figure.walk",
                      bullets: [L10n.helpCare1, L10n.helpCare2]),
            HelpTopic(id: "backup", title: L10n.helpTopicBackup,
                      icon: "externaldrive",
                      bullets: [L10n.helpBackup1, L10n.helpBackup2]),
            HelpTopic(id: HelpTopic.voiceID, title: L10n.helpTopicVoice,
                      icon: "mic",
                      bullets: [L10n.helpVoice1, L10n.helpVoice2]),
        ]
    }
}

/// 教程主题页（静态条目 + 语音输入主题附带 [🔊 朗读] 出口）
struct HelpTopicView: View {
    let title: String
    let bullets: [String]
    /// 行为条件用稳定 id，不用本地化标题比对（改文案不丢朗读入口）。
    let isVoiceTopic: Bool
    @Environment(AppState.self) private var app

    var body: some View {
        WithPerceptionTracking {
            List(bullets, id: \.self) { b in
                Text(b).font(.body)
            }
                        .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出（V4.13 补齐）
            .tintedCanvas()
.navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isVoiceTopic {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            app.speak(bullets.joined(separator: "。"))
                        } label: {
                            Label(L10n.helpVoiceSpeak, systemImage: "speaker.wave.2")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - FR22.2 权限诊断

/// FR22.2 权限诊断：汇总相机、麦克风、通知、Face ID、HealthKit 权限状态，
/// 只引导到系统设置，不循环弹系统授权框。
struct HelpPermissionDiagnostics: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraStatus: DiagnosticStatus = .checking
    @State private var micStatus: DiagnosticStatus = .checking
    @State private var notificationStatus: DiagnosticStatus = .checking
    @State private var faceIDStatus: DiagnosticStatus = .checking

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section(L10n.helpPermSection) {
                    PermissionRow(name: L10n.helpPermCamera, status: cameraStatus, icon: "camera")
                    PermissionRow(name: L10n.helpPermMic, status: micStatus, icon: "mic")
                    PermissionRow(name: L10n.helpPermNotification, status: notificationStatus, icon: "bell")
                    PermissionRow(name: "Face ID", status: faceIDStatus, icon: "faceid")
                }
                OpenSettingsSection(footer: L10n.helpPermDeniedHint)
            }
                        .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出（V4.13 补齐）
            .tintedCanvas()
.navigationTitle(L10n.helpDiagPermission)
            .task { await checkPermissions() }
            // 本页自带「打开系统设置」：回前台必须重采样，否则用户改完权限
            // 回来仍看到旧快照（.task 不会因同页回前台重跑）。
            .onChangeCompat(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await checkPermissions() }
            }
        }
    }

    private func checkPermissions() async {
        // Camera / Microphone（同口径映射，收敛 AuthorizationStatusLabel）
        cameraStatus = AuthorizationStatusLabel.capture(AVCaptureDevice.authorizationStatus(for: .video))
        micStatus = AuthorizationStatusLabel.capture(AVCaptureDevice.authorizationStatus(for: .audio))
        // Notifications
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = AuthorizationStatusLabel.notification(settings.authorizationStatus)
        // Face ID 可用性（LAContext 可判 canEvaluatePolicy，无授权弹窗）。
        // 必须用生物识别策略：.deviceOwnerAuthentication 把「设备密码」也算
        // 可用——Face ID 关闭/未注册但有密码的设备会误报「已授权」。
        var error: NSError?
        let biometry = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                     error: &error)
        faceIDStatus = biometry ? .authorized : .requiresDevice
    }
}

/// 权限/提醒诊断共用的「打开系统设置」区块（此前两处逐行复制）。
private struct OpenSettingsSection: View {
    let footer: String

    var body: some View {
        Section {
            Button(L10n.helpPermOpenSettings) {
                SystemLinks.openSettings()
            }
            .frame(minHeight: 44)
        } footer: {
            Text(footer)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PermissionRow: View {
    let name: String
    let status: DiagnosticStatus
    let icon: String

    var body: some View {
        WithPerceptionTracking {
            // T3 呈现评审:手写 Text+Spacer+值 行 → LabeledContent(标准行形态)
            LabeledContent {
                Text(status.text)
                    .foregroundStyle(status.isPositive ? Color("semantic-success", bundle: .main) : .secondary)
            } label: {
                Label(name, systemImage: icon)
            }
        }
    }
}

// MARK: - FR22.3 提醒诊断

/// FR22.3 提醒诊断：显示通知权限、计划状态、下次计划时间、
/// 最近调度/送达结果、时区变化和系统限制。
struct HelpReminderDiagnostics: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ReminderStore.self) private var reminderStore
    @State private var notificationStatus: DiagnosticStatus = .checking
    // 审查清理：hasSchedule 死状态（全仓仅此一处声明，零读写）——旧「计划状态」行
    // 已被已排内容展示取代，删除以免误导后续编辑者重建重复摘要。

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section(L10n.helpReminderSection) {
                    LabeledContent(L10n.helpReminderPermission) {
                        Text(notificationStatus.text)
                            .foregroundStyle(notificationStatus.isPositive ? Color("semantic-success", bundle: .main) : .secondary)
                    }
                }
                Section(L10n.helpReminderTodaySection) {
                    LabeledContent(L10n.helpReminderPendingDoses) {
                        Text("\(reminderStore.pendingCount)")
                            .foregroundStyle(reminderStore.pendingCount > 0 ? Color("semantic-warning", bundle: .main) : .secondary)
                    }
                    LabeledContent(L10n.helpReminderTodaySlots) {
                        Text("\(reminderStore.todaySlots.count)")
                    }
                }
                OpenSettingsSection(footer: L10n.helpReminderDeniedHint)
            }
                        .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出（V4.13 补齐）
            .tintedCanvas()
.navigationTitle(L10n.helpDiagReminder)
            .task { await checkNotificationStatus() }
            // 同上：从系统设置返回时重采样通知授权态。
            .onChangeCompat(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await checkNotificationStatus() }
            }
        }
    }

    private func checkNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = AuthorizationStatusLabel.notification(settings.authorizationStatus)
    }
}

// MARK: - FR22.4 数据与存储健康

/// FR22.4 数据与存储健康：展示数据库完整性、存储占用、最近备份状态。
struct HelpDataHealth: View {
    @Environment(AppState.self) private var app
    @State private var dbIntegrity: DiagnosticStatus = .checking
    @State private var storageSize: String = L10n.helpDataCalculating
    @State private var lastBackup: String = L10n.helpDataNoBackup

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section(L10n.helpDataDbSection) {
                    LabeledContent(L10n.helpDataIntegrity) {
                        Text(dbIntegrity.text)
                            .foregroundStyle(dbIntegrity.isPositive ? Color("semantic-success", bundle: .main) : .secondary)
                    }
                }
                Section(L10n.helpDataStorageSection) {
                    LabeledContent(L10n.helpDataDbSize, value: storageSize)
                }
                Section(L10n.helpDataBackupSection) {
                    LabeledContent {
                        Text(lastBackup).foregroundStyle(.secondary)
                    } label: {
                        Text(L10n.helpDataLastBackup)
                    }
                }
            }
                        .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出（V4.13 补齐）
            .tintedCanvas()
.navigationTitle(L10n.helpDataTitle)
            .task { await checkHealth() }
        }
    }

    private func checkHealth() async {
        // 最近备份：纯内存时间戳，不依赖 DB 查询——先取值，避免 DB 诊断
        // 慢/失败时备份行长时间停在占位文案（F22.4 联动 FR13.10）。
        if let at = app.lastBackupAt {
            lastBackup = Date(timeIntervalSince1970: at).formatted(date: .abbreviated, time: .shortened)
        } else {
            lastBackup = L10n.helpDataNoBackup
        }
        // FR22.4 数据健康必须给真实值：PRAGMA 实测逻辑库大小与完整性，
        // 不允许硬编码「正常」充当诊断
        do {
            let (bytes, ok) = try await app.databaseHealth()
            // 成熟实现优先：字节单位/进位走系统 ByteCountFormatter（与仓库
            // 其余体积展示同口径），不手写 /1_048_576 + 固定 "MB"。
            storageSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            // 审查修复：integrity_check 非 ok 是「已知损坏」的实测结果，
            // 伪装成「未知」让用户无从得知数据已损坏（FR22.4 诊断目的落空）
            dbIntegrity = ok ? .normal : .corrupt
        } catch {
            dbIntegrity = .unknown
            storageSize = L10n.helpStatusUnknown
        }
    }
}

// MARK: - FR22.8 关于页

/// F22 关于页（FR22.8）：版本三部件 + 开源许可 + 法律声明 + 产品定位。
struct HelpAboutView: View {
    @Environment(DocumentExportState.self) private var exportState
    /// 2026-11-05 业主：识别调参诊断开关移到「关于」页（原帮助中心根页）。
    @AppStorage(OCRShadowDiagnostics.defaultsKey) private var ocrShadowEnabled = false
    @State private var showOcrShadowConsent = false

    /// 三部件版本（FR22.8）：Version <GitHub Release> Build <CI 构建序号> Code Hash <提交哈希>
    private var buildInfo: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let hash = info?["VitaLiberBuildHash"] as? String ?? "dev"
        return L10n.helpVersion(version, build, hash)
    }

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section(L10n.helpAboutSection) {
                    Text(L10n.help_appName)
                    Text(buildInfo)
                        .accessibilityIdentifier("SP-48.about.version")
                    Text(L10n.help_tagline)
                }
                Section {
                    Toggle(isOn: Binding(
                        get: { ocrShadowEnabled },
                        set: { enabled in
                            if enabled {
                                showOcrShadowConsent = true
                            } else {
                                ocrShadowEnabled = false
                                Task { await exportState.removeAllDebugLogs() }
                            }
                        })) {
                        Label(L10n.helpOcrShadowToggle, systemImage: "doc.text.magnifyingglass")
                    }
                    .accessibilityHint(L10n.helpOcrShadowHint)
                    .accessibilityIdentifier("SP-48.about.ocrShadowDiagnostics")
                    .alert(L10n.helpOcrShadowTitle, isPresented: $showOcrShadowConsent) {
                        Button(L10n.helpOcrShadowConfirm, role: .destructive) {
                            ocrShadowEnabled = true
                        }
                        Button(L10n.commonCancel, role: .cancel) {}
                    } message: {
                        Text(L10n.helpOcrShadowHint)
                    }
                } header: {
                    Text(L10n.helpOcrShadowTitle)
                } footer: {
                    Text(L10n.helpOcrShadowHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.helpLegalSection) {
                    Text(L10n.help_disclaimer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    NavigationLink(L10n.helpTermsTitle) {
                        Text(L10n.help_privacyPlaceholder)
                            .padding()
                            .accessibilityIdentifier("SP-47.terms.body")
                    }
                    .accessibilityIdentifier("SP-47.terms.entry")
                }
                Section(L10n.helpAboutLicenses) {
                    Text("GRDB.swift — MIT License")
                    Text("ZIPFoundation — MIT License")
                    Text(L10n.helpAnatomyAttribution)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section(L10n.helpSection) {
                    Text(L10n.help_faqPlaceholder)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
                        .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出（V4.13 补齐）
            .tintedCanvas()
.navigationTitle(L10n.help_title)
        }
    }
}
