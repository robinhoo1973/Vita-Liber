import SwiftUI
import UIKit
import Domain
import Perception

/// FR14.1 分目的授权面板（ui-ux §5.22.2）：七项可执行开关 + 两项说明行。
/// 撤回即时生效（BR-010）——消费点在权限检查点实时读 AppSettingsStore.values，
/// 关闭只停后续处理、不删已有数据（FR14.7 诚实性：无消费点开关一律不上架）。
struct PrivacyAuthorizationView: View {
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router

    /// 八项可执行开关（顺序即面板顺序；healthWriteBack 随 2026-09-17 写回落地入列）
    private let authKeys: [AppSettingKey] = [
        .authOcr, .authAI, .authFamilyAccess, .authSharing,
        .authCloudBackup, .authHealthRead, .authVoiceDictation,
        .healthWriteBack
    ]

    var body: some View {
        WithPerceptionTracking {
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
                        SystemLinks.openSettings()
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
    }

    private func binding(for key: AppSettingKey) -> Binding<Bool> {
        Binding(
            // 审查修复（口径统一，FR14.1 同意面）：此前是 `values[key] != "false"`——
            // 在 values 未装载（nil，`.task { await settings.load() }` 尚未返回）时
            // **恒为 true** 显示为开，而客户端真实判定走 SettingsRules.resolved/
            // defaultValue。本页 key 含默认值 "false" 的 healthWriteBack（写回
            // Apple 健康，默认关）：冷启动进入本页的那一帧，「写回 Apple 健康」被
            // 显示为**开**（副标题却写「默认关」），用户据此以为读数已在写回；
            // 若在该窗口点开关试图「打开」，界面已显示为开 → 实际写入 "false"
            // （无变化）→ 开关回落成关，用户看到「开了又自己关了」。
            // 与 SettingsViews.swift:216 同款口径：按键默认值解析，装载前后一致。
            get: { SettingsRules.resolved(settings.values[key], key: key) == "true" },
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
        case .healthWriteBack: return L10n.privacyAuthWriteBackTitle
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
        case .healthWriteBack: return L10n.privacyAuthWriteBackSub
        default: return ""
        }
    }
}
