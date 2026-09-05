import SwiftUI
import UIKit
import Domain

/// FR14.1 分目的授权面板（ui-ux §5.22.2）：七项可执行开关 + 两项说明行。
/// 撤回即时生效（BR-010）——消费点在权限检查点实时读 AppSettingsStore.values，
/// 关闭只停后续处理、不删已有数据（FR14.7 诚实性：无消费点开关一律不上架）。
struct PrivacyAuthorizationView: View {
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router

    /// 七项可执行开关（顺序即面板顺序）
    private let authKeys: [AppSettingKey] = [
        .authOcr, .authAI, .authFamilyAccess, .authSharing,
        .authCloudBackup, .authHealthRead, .authVoiceDictation
    ]

    var body: some View {
        Form {
            Section {
                ForEach(authKeys, id: \.self) { key in
                    Toggle(isOn: binding(for: key)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(key))
                            Text(Self.subtitle(key))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("FR14.1.\(key.rawValue)")
                    .accessibilityLabel("\(Self.title(key))：\(Self.subtitle(key))")
                }
            } footer: {
                Text(L10n.privacyAuthFooter)
            }
            Section(L10n.privacyAuthExplainers) {
                // 非开关说明行（FR14.7 诚实性）：本地存储=永久免费红线、
                // 匿名化改进=离线优先红线（本应用无上传通道）
                Label(L10n.privacyAuthStorageNote, systemImage: "internaldrive")
                    .font(.footnote)
                Label(L10n.privacyAuthAnonymizedNote, systemImage: "wifi.slash")
                    .font(.footnote)
                // 位置权限（SOS 发送位置）= 系统级权限 → 系统设置深链（FR20.2）
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label(L10n.privacyAuthLocationNote, systemImage: "location.slash")
                        .font(.footnote)
                }
                .accessibilityIdentifier("FR14.1.location.settings")
            }
        }
        .navigationTitle(L10n.privacyAuthTitle)
        .task { await settings.load() }
    }

    private func binding(for key: AppSettingKey) -> Binding<Bool> {
        Binding(
            get: { settings.values[key] != "false" },   // 未设置 = 允许（默认真源在 defaultValue）
            set: { newValue in
                Task { await settings.set(newValue ? "true" : "false", for: key) }
            })
    }

    static func title(_ key: AppSettingKey) -> String {
        switch key {
        case .authOcr: return L10n.privacyAuthOcrTitle
        case .authAI: return L10n.privacyAuthAITitle
        case .authFamilyAccess: return L10n.privacyAuthFamilyTitle
        case .authSharing: return L10n.privacyAuthSharingTitle
        case .authCloudBackup: return L10n.privacyAuthBackupTitle
        case .authHealthRead: return L10n.privacyAuthHealthTitle
        case .authVoiceDictation: return L10n.privacyAuthVoiceTitle
        default: return key.rawValue
        }
    }

    static func subtitle(_ key: AppSettingKey) -> String {
        switch key {
        case .authOcr: return L10n.privacyAuthOcrSub
        case .authAI: return L10n.privacyAuthAISub
        case .authFamilyAccess: return L10n.privacyAuthFamilySub
        case .authSharing: return L10n.privacyAuthSharingSub
        case .authCloudBackup: return L10n.privacyAuthBackupSub
        case .authHealthRead: return L10n.privacyAuthHealthSub
        case .authVoiceDictation: return L10n.privacyAuthVoiceSub
        default: return ""
        }
    }
}
