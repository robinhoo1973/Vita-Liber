import SwiftUI
import Domain

/// §5.58 提醒触达设置（FR9.18/FR14.7 · V3.72 点亮）：每类提醒三选一
/// （仅通知 / 通知+响铃直到确认 / 静音仅横幅）+ 应用内横幅总开关。
/// 偏好写 app_settings（AppSettingKey 单一事实源）。
/// 第七轮全仓审查修复接线：偏好此前零生产消费方（假宣告）——
/// 「静音仅横幅」现经 ChannelGatedScheduler（AppContainer 装配的调度器
/// 装饰器，Domain 规则 = ReminderChannelRules）真实生效：该类别的系统
/// 通知投递被跳过，应用内横幅是唯一通道；「仅通知」为现状；「响铃直到
/// 确认」在 Critical Alerts entitlement（P2/W4）申请前按降级链落到
/// 通知照常投递（footer 已如实说明）。偏好变更只作用于新排程通知，
/// 已 pending 的旧通知在下次对账/语言重写时收敛（登记技术债）。
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-26.remch.list")
    }
}
