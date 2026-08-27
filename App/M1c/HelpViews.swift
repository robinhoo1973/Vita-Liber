import SwiftUI
import Domain

/// F22 帮助与关于（M1c 滞留清偿）：SP-47 条款入口 + 免责声明 + 版本。
struct HelpAboutView: View {
    var body: some View {
        Form {
            Section("关于") {
                Text(L10n.help_appName)
                Text(L10n.help_version)
                Text(L10n.help_tagline)
            }
            Section("法律与免责声明") {
                Text(L10n.help_disclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink("隐私政策与服务条款（SP-47）") {
                    Text(L10n.help_privacyPlaceholder)
                        .padding()
                        .accessibilityIdentifier("SP-47.terms.body")
                }
                .accessibilityIdentifier("SP-47.terms.entry")
            }
            Section("帮助") {
                Text(L10n.help_faqPlaceholder)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.help_title)
    }
}
