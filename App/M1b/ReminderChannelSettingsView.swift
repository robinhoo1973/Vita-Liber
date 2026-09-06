import SwiftUI
import Domain

/// §5.58 提醒触达设置（FR9.18/FR14.7 · V3.72 点亮）：每类提醒三选一
/// （仅通知 / 通知+响铃直到确认 / 静音仅横幅）+ 应用内横幅总开关。
/// 偏好写 app_settings（AppSettingKey 单一事实源）；UNReminderScheduler 消费
/// ChannelFallback.fallbackChain 的接线随 W4（persistentRing 依赖 Critical Alerts
/// entitlement，P2 申请）。
struct ReminderChannelSettingsView: View {
    @Environment(AppSettingsStore.self) private var settings

    /// 六类提醒（§5.44 六源中的可提醒类）
    private let categories: [(key: AppSettingKey, nameKey: String)] = [
        (.remindChannelMeds, L10n.remchMeds),
        (.remindChannelApts, L10n.remchApts),
        (.remindChannelExam, L10n.remchExam),
        (.remindChannelExpiry, L10n.remchExpiry),
        (.remindChannelAlert, L10n.remchAlert),
        (.remindChannelBackup, L10n.remchBackup),
    ]

    var body: some View {
        List {
            Section {
                ForEach(categories, id: \.key) { cat in
                    Picker(selection: Binding(
                        get: { settings.values[cat.key] ?? cat.key.defaultValue },
                        set: { v in Task { await settings.set(v, for: cat.key) } }
                    )) {
                        Text(L10n.remchLocal).tag("local")
                        Text(L10n.remchRing).tag("persistentRing")
                        Text(L10n.remchInApp).tag("inApp")
                    } label: {
                        Text(cat.nameKey)
                    }
                }
            } header: {
                Text(L10n.remchSectionHint)
            } footer: {
                Text(L10n.remchSectionFooter)
            }
            Section {
                Toggle(L10n.remchBannerToggle, isOn: Binding(
                    get: { settings.values[.inAppBannerEnabled] != "false" },
                    set: { on in Task { await settings.set(on ? "true" : "false", for: .inAppBannerEnabled) } }
                ))
                .accessibilityIdentifier("SP-26.remch.bannerToggle")
            } footer: {
                Text(L10n.remchBannerFooter)
            }
        }
        .navigationTitle(L10n.remchTitle)
        .accessibilityIdentifier("SP-26.remch.list")
    }
}
