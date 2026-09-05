import SwiftUI
import Domain

// MARK: - FR14.7 常用习惯设置（SP-26 · ui-ux §5.19）

/// 偏好中心：提醒/显示与单位/语音与关怀分组，每项显示当前值、
/// 影响范围标签（仅新建 / 全局生效——FR14.7 追溯语义）与 [恢复默认]。
struct PreferencesView: View {
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppState.self) private var app
    @State private var readback = "never"

    var body: some View {
        Form {
            // 审查修复（诚实性）：remindAdvance/snooze/quietHours/notifPreviewMed/
            // 通道/日期格式/单位/动效/排序等十余项偏好此前只写不读
            // （全仓零消费点）——「可调但无效果」的开关违反 FR14.7
            // 「偏好必须真实生效」，已从 UI 移除并登记技术债；接线后恢复。
            // 现仅保留真实生效项：无耳机回读偏好（FR17.13 运行时真源已接线）。
            Section {
                Picker(L10n.prefReadback, selection: $readback) {
                    Text(L10n.prefReadbackNever).tag("never")
                    Text(L10n.prefReadbackAsk).tag("ask")
                    Text(L10n.prefReadbackAlways).tag("alwaysInCareMode")
                }
                // 审查修复：禁用态不得由「当前选中值」推导——关怀模式关闭后
                // readback=alwaysInCareMode 时 isSelectable=false，整个 Picker
                // 被禁用，用户再也改不回 never/ask（恢复默认又被 onDisappear
                // 的 save() 用陈旧 @State 覆盖）。始终可选；非法组合由
                // AppState.readbackPreference 写入口按 ReadbackPolicy 拒绝。
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
        readback = settings.values[.readBackOptIn] ?? "never"
    }

    private func save() {
        // ReadbackPolicy：总是 仅关怀模式可选——非法组合不落盘
        // （保留原值，配合 AppState.readbackPreference 写入口的同一道校验）
        let pref = ReadbackPreference(rawValue: readback) ?? .never
        guard ReadbackPolicy.isSelectable(pref, careMode: app.careMode) else { return }
        Task {
            await settings.set(readback, for: .readBackOptIn)
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
