import SwiftUI
import Domain

// MARK: - FR14.7 常用习惯设置（SP-26 · ui-ux §5.19）

/// 偏好中心：提醒/显示与单位/语音与关怀分组，每项显示当前值、
/// 影响范围标签（仅新建 / 全局生效——FR14.7 追溯语义）与 [恢复默认]。
struct PreferencesView: View {
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppState.self) private var app
    @State private var remindAdvance = ""
    @State private var snooze = ""
    @State private var quietStart = ""
    @State private var quietEnd = ""
    @State private var dateFormat = ""
    @State private var weekStart = ""
    @State private var unitSystem = "metric"
    @State private var reduceMotion = false
    @State private var homeSort = "time"
    @State private var notifPreviewMed = false
    @State private var readback = "never"
    @State private var channel = "local"

    var body: some View {
        Form {
            // 提醒组（FR14.7）
            Section {
                TextField(L10n.prefRemindAdvance, text: $remindAdvance)
                    .keyboardType(.numberPad)
                TextField(L10n.prefSnooze, text: $snooze)
                    .keyboardType(.numberPad)
                HStack {
                    TextField(L10n.prefQuietStart, text: $quietStart)
                    Text(L10n.prefTo)
                    TextField(L10n.prefQuietEnd, text: $quietEnd)
                }
                // FR9.18 通道偏好（全局生效——影响下一次提醒的送达通道选择）
                Picker(L10n.prefChannel, selection: $channel) {
                    Text(L10n.prefChannelNotifyOnly).tag("local")
                    Text(L10n.prefChannelRingUntilConfirm).tag("persistentRing")
                    Text(L10n.prefChannelSilentBanner).tag("inApp")
                }
                Toggle(L10n.prefNotifPreviewMed, isOn: $notifPreviewMed)
            } header: {
                LabeledContent(L10n.prefGroupReminders) {
                    Text(L10n.prefTagGlobal)   // 通道偏好与通知预览=全局生效（FR14.7 例外②）
                }
            } footer: {
                Text(L10n.prefRemindScopeNote)
            }
            // 显示与单位组（仅新建语义）
            Section {
                TextField(L10n.prefDateFormat, text: $dateFormat)
                TextField(L10n.prefWeekStart, text: $weekStart)
                    .keyboardType(.numberPad)
                Picker(L10n.prefUnitSystem, selection: $unitSystem) {
                    Text(L10n.prefUnitMetric).tag("metric")
                    Text(L10n.prefUnitImperial).tag("imperial")
                }
                Toggle(L10n.prefReduceMotion, isOn: $reduceMotion)
                Picker(L10n.prefHomeSort, selection: $homeSort) {
                    Text(L10n.prefHomeSortTime).tag("time")
                    Text(L10n.prefHomeSortType).tag("type")
                }
            } header: {
                LabeledContent(L10n.prefGroupDisplay) {
                    Text(L10n.prefTagNewOnly)   // 仅影响新建项（FR14.7 追溯语义）
                }
            }
            // 语音与关怀组（FR17.13 无耳机回读偏好三态）
            Section {
                Picker(L10n.prefReadback, selection: $readback) {
                    Text(L10n.prefReadbackNever).tag("never")
                    Text(L10n.prefReadbackAsk).tag("ask")
                    Text(L10n.prefReadbackAlways).tag("alwaysInCareMode")
                }
                .disabled(!ReadbackPolicy.isSelectable(
                    ReadbackPreference(rawValue: readback) ?? .never, careMode: app.careMode))
            } header: {
                LabeledContent(L10n.prefGroupVoice) {
                    Text(L10n.prefTagGlobal)
                }
            } footer: {
                Text(L10n.prefReadbackHint)
            }
            // 恢复默认（逐项）
            Section {
                Button(L10n.prefRestoreAll) {
                    Task { await settings.restoreDefaults() }
                }
            }
        }
        .navigationTitle(L10n.settings_habits)
        .task {
            await settings.load()
            loadValues()
        }
        .onDisappear { save() }
    }

    private func loadValues() {
        remindAdvance = settings.values[.remindAdvanceMinutes] ?? "-"
        snooze = settings.values[.snoozeMinutes] ?? "-"
        quietStart = settings.values[.quietHoursStart] ?? "-"
        quietEnd = settings.values[.quietHoursEnd] ?? "-"
        dateFormat = settings.values[.dateFormat] ?? "-"
        weekStart = settings.values[.weekStartsOn] ?? "-"
        unitSystem = settings.values[.unitSystem] ?? "metric"
        reduceMotion = settings.values[.reduceMotion] == "true"
        homeSort = settings.values[.homeSort] ?? "time"
        notifPreviewMed = settings.values[.notificationPreviewMedName] == "true"
        readback = settings.values[.readBackOptIn] ?? "never"
        channel = settings.values[.remindChannel] ?? "local"
    }

    private func save() {
        Task {
            await settings.set(remindAdvance, for: .remindAdvanceMinutes)
            await settings.set(snooze, for: .snoozeMinutes)
            await settings.set(quietStart, for: .quietHoursStart)
            await settings.set(quietEnd, for: .quietHoursEnd)
            await settings.set(dateFormat, for: .dateFormat)
            await settings.set(weekStart, for: .weekStartsOn)
            await settings.set(unitSystem, for: .unitSystem)
            await settings.set(reduceMotion ? "true" : "false", for: .reduceMotion)
            await settings.set(homeSort, for: .homeSort)
            await settings.set(notifPreviewMed ? "true" : "false", for: .notificationPreviewMedName)
            await settings.set(readback, for: .readBackOptIn)
            await settings.set(channel, for: .remindChannel)
        }
    }
}

// MARK: - FR14.3 数据生命周期页（四级删除语义 + 影响清单）

/// 数据生命周期：删除单条 / 删除成员 / 清空全部 / 注销（P1 账户化）——
/// 每级明示活动数据、缓存、备份、日志的处理状态；执行前展示影响清单。
struct DataLifecycleView: View {
    @Environment(AppState.self) private var app
    @State private var showClearConfirm = false
    @State private var clearing = false

    var body: some View {
        List {
            Section(L10n.lifecycleSingle) {
                Text(L10n.lifecycleSingleHint)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section(L10n.lifecycleMember) {
                Text(L10n.lifecycleMemberHint)
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink(L10n.member_title) {
                    MemberManagementView()
                }
            }
            Section(L10n.lifecycleClearAll) {
                Text(L10n.lifecycleClearHint)
                    .font(.footnote).foregroundStyle(.secondary)
                Button(L10n.lifecycleClearButton, role: .destructive) {
                    showClearConfirm = true
                }
                .accessibilityIdentifier("FR14.3.clearAll")
            }
            Section(L10n.lifecycleLogout) {
                Text(L10n.lifecycleLogoutHint)
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.settings_dataLifecycle)
        // FR14.3 执行前影响清单确认
        .confirmationDialog(L10n.lifecycleClearButton, isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button(L10n.lifecycleClearButton, role: .destructive) {
                Task {
                    clearing = true
                    do {
                        try await app.persistorReset()
                        clearing = false
                    } catch {
                        clearing = false
                    }
                }
            }
            Button(L10n.commonCancel, role: .cancel) { }
        } message: {
            Text(L10n.lifecycleClearImpact)
        }
    }
}
