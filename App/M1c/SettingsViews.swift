import SwiftUI
import Domain

/// F14 设置中心（SP 系列 M1c 切片）：分目的授权九开关（FR14.1 独立开关语义）、
/// 常用习惯（FR14.7）、审计与关于入口。
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(AppSettingsStore.self) private var settings
    @State private var toggles: [AppSettingKey: Bool] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section("授权（独立开关，关掉即停）") {
                    ForEach(authKeys, id: \.rawValue) { key in
                        Toggle(isOn: binding(for: key)) {
                            Text(label(for: key))
                        }
                        .accessibilityIdentifier("SP-25.setting.\(key.rawValue)")
                    }
                }
                Section("常用习惯") {
                    Text("提醒提前量：\(settings.values[.remindAdvanceMinutes] ?? "-") 分钟")
                    Text("稍后时长：\(settings.values[.snoozeMinutes] ?? "-") 分钟")
                    Text("安静时段：\(settings.values[.quietHoursStart] ?? "-") - \(settings.values[.quietHoursEnd] ?? "-")")
                }
                Section("Pro") {
                    NavigationLink("Pro 升级与恢复") {
                        PaywallView()
                    }
                    .accessibilityIdentifier("SP-25.settings.pro")
                }
                Section("隐私与数据") {
                    NavigationLink("审计记录") {
                        AuditLogView()
                    }
                    .accessibilityIdentifier("SP-25.settings.audit")
                    Button("恢复默认设置") {
                        Task { try await settings.restoreDefaults() }
                    }
                }
                Section("关于") {
                    NavigationLink("帮助与关于") {
                        HelpAboutView()
                    }
                    .accessibilityIdentifier("SP-25.settings.help")
                    Text("本 App 不是医疗设备，不下诊断、不给治疗方案建议。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的")
        }
        .task { await settings.load() }
    }

    /// FR14.1 分目的授权开关（M1c 已落键的两项；其余随功能模块上线逐步接入）
    private var authKeys: [AppSettingKey] {
        [.careModeEnable, .voiceEntryVisible]
    }

    private func binding(for key: AppSettingKey) -> Binding<Bool> {
        Binding(
            get: { toggles[key] ?? false },
            set: { newValue in
                toggles[key] = newValue
                Task { try await settings.set(newValue ? "true" : "false", for: key) }
            })
    }

    private func label(for key: AppSettingKey) -> String {
        switch key {
        case .careModeEnable: return "关怀模式"
        case .voiceEntryVisible: return "语音快速入口"
        default: return key.rawValue
        }
    }
}

/// 审计记录页（FR14.2）：append-only 事实列表
struct AuditLogView: View {
    @Environment(AppSettingsStore.self) private var settings
    var body: some View {
        List(settings.auditEntries, id: \.id) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.action).font(.subheadline)
                Text("\(entry.entityType) · \(entry.at.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("审计记录")
        .task { await settings.loadAudit() }
    }
}
