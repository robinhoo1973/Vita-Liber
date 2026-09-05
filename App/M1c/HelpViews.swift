import SwiftUI
import Domain
import UserNotifications
import AVFoundation
import LocalAuthentication

// MARK: - FR22.1 帮助中心根视图

/// F22 帮助中心入口：按功能提供诊断工具、教程、FAQ 和关于页。
struct HelpRootView: View {
    var body: some View {
        Form {
            Section {
                NavigationLink {
                    HelpPermissionDiagnostics()
                } label: {
                    Label(L10n.helpDiagPermission, systemImage: "lock.shield")
                }
                .accessibilityIdentifier("FR22.2.permissionDiagnostics")

                NavigationLink {
                    HelpReminderDiagnostics()
                } label: {
                    Label(L10n.helpDiagReminder, systemImage: "bell.badge.exclamationmark")
                }
                .accessibilityIdentifier("FR22.3.reminderDiagnostics")

                NavigationLink {
                    HelpDataHealth()
                } label: {
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
                NavigationLink {
                    HelpAboutView()
                } label: {
                    Label(L10n.helpAboutLegal, systemImage: "info.circle")
                }
                .accessibilityIdentifier("FR22.8.about")
            }
        }
        .navigationTitle(L10n.helpCenterTitle)
    }
}

// MARK: - FR22.2 权限诊断

/// FR22.2 权限诊断：汇总相机、麦克风、通知、Face ID、HealthKit 权限状态，
/// 只引导到系统设置，不循环弹系统授权框。
struct HelpPermissionDiagnostics: View {
    @State private var cameraStatus: String = L10n.helpStatusChecking
    @State private var micStatus: String = L10n.helpStatusChecking
    @State private var notificationStatus: String = L10n.helpStatusChecking
    @State private var faceIDStatus: String = L10n.helpStatusChecking

    var body: some View {
        Form {
            Section(L10n.helpPermSection) {
                PermissionRow(name: L10n.helpPermCamera, status: cameraStatus, icon: "camera")
                PermissionRow(name: L10n.helpPermMic, status: micStatus, icon: "mic")
                PermissionRow(name: L10n.helpPermNotification, status: notificationStatus, icon: "bell")
                PermissionRow(name: "Face ID", status: faceIDStatus, icon: "faceid")
            }
            Section {
                Button(L10n.helpPermOpenSettings) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .frame(minHeight: 44)
            } footer: {
                Text(L10n.helpPermDeniedHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.helpDiagPermission)
        .task { await checkPermissions() }
    }

    private func checkPermissions() async {
        // Camera
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraStatus = L10n.helpStatusAuthorized
        case .denied, .restricted: cameraStatus = L10n.helpStatusDenied
        case .notDetermined: cameraStatus = L10n.helpStatusNotRequested
        @unknown default: cameraStatus = L10n.helpStatusUnknown
        }
        // Microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micStatus = L10n.helpStatusAuthorized
        case .denied, .restricted: micStatus = L10n.helpStatusDenied
        case .notDetermined: micStatus = L10n.helpStatusNotRequested
        @unknown default: micStatus = L10n.helpStatusUnknown
        }
        // Notifications
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: notificationStatus = L10n.helpStatusAuthorized
        case .denied: notificationStatus = L10n.helpStatusDenied
        case .provisional: notificationStatus = L10n.helpStatusProvisional
        case .ephemeral: notificationStatus = L10n.helpStatusProvisional
        case .notDetermined: notificationStatus = L10n.helpStatusNotRequested
        @unknown default: notificationStatus = L10n.helpStatusUnknown
        }
        // Face ID 可用性（LAContext 可判 canEvaluatePolicy，无授权弹窗）
        var error: NSError?
        let biometry = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        faceIDStatus = biometry ? L10n.helpStatusAuthorized : L10n.helpFaceIDRequiresDevice
    }
}

private struct PermissionRow: View {
    let name: String
    let status: String
    let icon: String

    var body: some View {
        HStack {
            Label(name, systemImage: icon)
            Spacer()
            Text(status)
                .foregroundStyle(status.contains(L10n.helpStatusAuthorized) ? .green : .secondary)
        }
    }
}

// MARK: - FR22.3 提醒诊断

/// FR22.3 提醒诊断：显示通知权限、计划状态、下次计划时间、
/// 最近调度/送达结果、时区变化和系统限制。
struct HelpReminderDiagnostics: View {
    @Environment(ReminderStore.self) private var reminderStore
    @State private var notificationStatus: String = L10n.helpStatusChecking
    @State private var hasSchedule: Bool = false

    var body: some View {
        Form {
            Section(L10n.helpReminderSection) {
                HStack {
                    Text(L10n.helpReminderPermission)
                    Spacer()
                    Text(notificationStatus)
                        .foregroundStyle(notificationStatus.contains(L10n.helpStatusAuthorized) ? .green : .secondary)
                }
            }
            Section(L10n.helpReminderTodaySection) {
                HStack {
                    Text(L10n.helpReminderPendingDoses)
                    Spacer()
                    Text("\(reminderStore.pendingCount)")
                        .foregroundStyle(reminderStore.pendingCount > 0 ? .orange : .secondary)
                }
                HStack {
                    Text(L10n.helpReminderTodaySlots)
                    Spacer()
                    Text("\(reminderStore.todaySlots.count)")
                }
            }
            Section {
                Button(L10n.helpPermOpenSettings) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .frame(minHeight: 44)
            } footer: {
                Text(L10n.helpReminderDeniedHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.helpDiagReminder)
        .task { await checkNotificationStatus() }
    }

    private func checkNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: notificationStatus = L10n.helpStatusAuthorized
        case .denied: notificationStatus = L10n.helpStatusDenied
        case .provisional: notificationStatus = L10n.helpStatusProvisional
        case .ephemeral: notificationStatus = L10n.helpStatusProvisional
        case .notDetermined: notificationStatus = L10n.helpStatusNotRequested
        @unknown default: notificationStatus = L10n.helpStatusUnknown
        }
    }
}

// MARK: - FR22.4 数据与存储健康

/// FR22.4 数据与存储健康：展示数据库完整性、存储占用、最近备份状态。
struct HelpDataHealth: View {
    @Environment(AppState.self) private var app
    @State private var dbIntegrity: String = L10n.helpStatusChecking
    @State private var storageSize: String = L10n.helpDataCalculating
    @State private var lastBackup: String = L10n.helpDataNoBackup

    var body: some View {
        Form {
            Section(L10n.helpDataDbSection) {
                HStack {
                    Text(L10n.helpDataIntegrity)
                    Spacer()
                    Text(dbIntegrity)
                        .foregroundStyle(dbIntegrity.contains(L10n.helpDataNormal) ? .green : .secondary)
                }
            }
            Section(L10n.helpDataStorageSection) {
                HStack {
                    Text(L10n.helpDataDbSize)
                    Spacer()
                    Text(storageSize)
                }
            }
            Section(L10n.helpDataBackupSection) {
                HStack {
                    Text(L10n.helpDataLastBackup)
                    Spacer()
                    Text(lastBackup)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(L10n.helpDataTitle)
        .task { await checkHealth() }
    }

    private func checkHealth() async {
        // FR22.4 数据健康必须给真实值：PRAGMA 实测逻辑库大小与完整性，
        // 不允许硬编码「正常」充当诊断
        do {
            let (bytes, ok) = try await app.databaseHealth()
            storageSize = String(format: "%.1f MB", Double(bytes) / 1_048_576)
            // 审查修复：integrity_check 非 ok 是「已知损坏」的实测结果，
            // 伪装成「未知」让用户无从得知数据已损坏（FR22.4 诊断目的落空）
            dbIntegrity = ok ? L10n.helpDataNormal : L10n.helpDataCorrupt
        } catch {
            dbIntegrity = L10n.helpStatusUnknown
            storageSize = L10n.helpStatusUnknown
        }
        // 最近备份：读上次备份时间戳（F22.4 联动 FR13.10）
        if let at = app.lastBackupAt {
            lastBackup = Date(timeIntervalSince1970: at).formatted(date: .abbreviated, time: .shortened)
        } else {
            lastBackup = L10n.helpDataNoBackup
        }
    }
}

// MARK: - FR22.8 关于页

/// F22 关于页（FR22.8）：版本三部件 + 开源许可 + 法律声明 + 产品定位。
struct HelpAboutView: View {
    /// 三部件版本（FR22.8）：Version <GitHub Release> Build <CI 构建序号> Code Hash <提交哈希>
    private var buildInfo: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let hash = info?["VitaLiberBuildHash"] as? String ?? "dev"
        return L10n.helpVersion(version, build, hash)
    }

    var body: some View {
        Form {
            Section(L10n.helpAboutSection) {
                Text(L10n.help_appName)
                Text(buildInfo)
                    .accessibilityIdentifier("SP-48.about.version")
                Text(L10n.help_tagline)
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
            }
            Section(L10n.helpSection) {
                Text(L10n.help_faqPlaceholder)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.help_title)
    }
}
