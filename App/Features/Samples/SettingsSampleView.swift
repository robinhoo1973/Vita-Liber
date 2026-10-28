#if DEBUG
import SwiftUI

/// 样张：设置屏（仅 DEBUG；2026-10-29 样张图库批）。
///
/// 演示要点：分组 Form（外观 / 通知 / 隐私 / 关于）、分段选择器、开关组、
/// 破坏性操作二次确认（alert）。全部 @State 本地态——不写 UserDefaults、
/// 不触真实设置仓（样张层不越界）。
/// 平台纪律：控件均为 iOS 16 可用面；开关行高 ≥44pt 由 Form 行天然满足；
/// 字符串全英文（L0 中文直写门不涉），标识符只挂叶子控件。
struct SettingsSampleView: View {
    private enum AppearanceChoice: String, CaseIterable, Identifiable {
        case light, dark, system
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @State private var appearance: AppearanceChoice = .system
    @State private var workoutAlerts = true
    @State private var weeklyDigest = false
    @State private var liveActivity = true
    @State private var faceIDLock = true
    @State private var analyticsOptIn = false
    @State private var showEraseConfirm = false

    var body: some View {
        Form {
            profileHeader
            appearanceSection
            notificationSection
            privacySection
            aboutSection
            destructiveSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Erase sample data?", isPresented: $showEraseConfirm) {
            Button("Erase", role: .destructive) { }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This only clears demo state in the sample gallery.")
        }
    }

    // MARK: - 分区

    private var profileHeader: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(VLFont.homeActionIcon)
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sample User")
                        .font(.headline)
                    Text("Local profile · samples only")
                        .font(.caption)
                        .foregroundStyle(Color("text-secondary", bundle: .main))
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                ForEach(AppearanceChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("sample.settings.appearance")
            LabeledContent("Accent") {
                HStack(spacing: 6) {
                    ForEach(["brand-primary", "semantic-success", "semantic-warning"], id: \.self) { name in
                        Circle()
                            .fill(Color(name, bundle: .main))
                            .frame(width: 18, height: 18)
                    }
                }
            }
        }
    }

    private var notificationSection: some View {
        Section("Notifications") {
            Toggle("Workout alerts", isOn: $workoutAlerts)
                .accessibilityIdentifier("sample.settings.notify.workout")
            Toggle("Weekly digest", isOn: $weeklyDigest)
                .accessibilityIdentifier("sample.settings.notify.digest")
            Toggle("Live activity", isOn: $liveActivity)
                .accessibilityIdentifier("sample.settings.notify.live")
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            Toggle("Require Face ID", isOn: $faceIDLock)
                .accessibilityIdentifier("sample.settings.privacy.faceid")
            Toggle("Share anonymous analytics", isOn: $analyticsOptIn)
                .accessibilityIdentifier("sample.settings.privacy.analytics")
            NavigationLink("Data & Storage") {
                storageDetail
            }
            .accessibilityIdentifier("sample.settings.privacy.storage")
        }
    }

    private var storageDetail: some View {
        List {
            LabeledContent("Sessions cached", value: "1")
            LabeledContent("Media stored", value: "0 B")
            Button("Clear cache", role: .destructive) { }
                .accessibilityIdentifier("sample.settings.storage.clear")
        }
        .navigationTitle("Data & Storage")
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: "0.0.0 (samples)")
            Link("Documentation", destination: URL(string: "https://example.com")!)
                .accessibilityIdentifier("sample.settings.about.docs")
        }
    }

    private var destructiveSection: some View {
        Section {
            Button("Erase sample data", role: .destructive) {
                showEraseConfirm = true
            }
            .accessibilityIdentifier("sample.settings.erase")
        }
    }
}

#Preview("Settings") {
    NavigationStack {
        SettingsSampleView()
    }
}
#endif
