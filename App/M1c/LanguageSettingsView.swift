import SwiftUI
import Domain

/// FR14.5 显示语言选择器（ui-ux §5.12.2）：zh-Hans / zh-Hant 二选，
/// 每项以该语言原文显示（多语言选择器业界惯例）；切换即时生效
/// （L10n.setLanguage → 视图重渲染 → 全部文案即时切换，无需重启）。
/// 选择持久化至偏好存储（app_settings.language），随备份/恢复迁移（FR14.5）。
struct LanguageSettingsView: View {
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppState.self) private var app

    private var current: String {
        settings.values[.language] ?? AppSettingKey.language.defaultValue
    }

    var body: some View {
        List {
            Section {
                ForEach(L10n.supportedDisplayLanguages, id: \.code) { lang in
                    Button {
                        Task {
                            await settings.set(lang.code, for: .language)
                            L10n.setLanguage(lang.code)   // 即时生效，无需重启
                        }
                    } label: {
                        HStack {
                            Text(lang.nativeName)   // 以该语言原文显示
                            Spacer()
                            if current == lang.code {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color("brand-primary", bundle: .main))
                            }
                        }
                    }
                    .accessibilityIdentifier("SP-25.language.\(lang.code)")
                }
            } footer: {
                Text(L10n.languageFooter)
            }
        }
        .navigationTitle(L10n.languageTitle)
    }
}


/// FR17.15/FR17.16 语音语言选择器（ui-ux §5.12.3）：
/// A. 输入语言多选（六语种；T2 方言「尽力识别」徽标；混合输入开关）
/// B. 输出语言单选（六选一；无方言发声时回退普通话并提示）
struct VoiceLanguageSettingsView: View {
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppState.self) private var app
    @State private var inputLangs: Set<String> = []
    @State private var mixEnabled = true

    private var outputLang: String {
        app.voiceOutputLocale
    }

    var body: some View {
        List {
            Section {
                ForEach(EngineCapabilityProfile.sixLanguages, id: \.locale) { lang in
                    Button {
                        toggleInput(lang.locale)
                    } label: {
                        HStack {
                            Text(lang.nativeName)
                            if lang.tier == .bestEffort {
                                Text(L10n.voiceLangBestEffort)
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color(.systemGray5)))
                            }
                            Spacer()
                            if inputLangs.contains(lang.locale) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color("brand-primary", bundle: .main))
                            }
                        }
                    }
                    .accessibilityIdentifier("SP-25.voiceInputLang.\(lang.locale)")
                }
            } header: {
                Text(L10n.voiceLangInputSection)
            } footer: {
                Text(L10n.voiceLangInputHint)
            }

            Section {
                Toggle(L10n.voiceLangMix, isOn: $mixEnabled)
            } footer: {
                Text(L10n.voiceLangMixHint)
            }

            Section {
                ForEach(EngineCapabilityProfile.sixLanguages, id: \.locale) { lang in
                    Button {
                        app.setVoiceOutputLocale(lang.locale)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lang.nativeName)
                                if lang.tier == .bestEffort {
                                    // FR17.16 发声回退链：方言无独立发声 → 普通话朗读
                                    Text(L10n.voiceLangFallback)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if outputLang == lang.locale {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color("brand-primary", bundle: .main))
                            }
                        }
                    }
                    .accessibilityIdentifier("SP-25.voiceOutputLang.\(lang.locale)")
                }
            } header: {
                Text(L10n.voiceLangOutputSection)
            } footer: {
                Text(L10n.voiceLangOutputHint)
            }
        }
        .navigationTitle(L10n.voiceLangTitle)
        .task { await load() }
    }

    private func load() async {
        let stored = settings.values[.voiceInputLanguages] ?? AppSettingKey.voiceInputLanguages.defaultValue
        inputLangs = Set(stored.split(separator: ",").map(String.init))
    }

    private func toggleInput(_ locale: String) {
        if inputLangs.contains(locale) {
            // 至少启用一项（FR17.15：全部关闭时入口置灰并引导恢复默认）
            guard inputLangs.count > 1 else { return }
            inputLangs.remove(locale)
        } else {
            inputLangs.insert(locale)
        }
        let joined = inputLangs.sorted().joined(separator: ",")
        Task { await settings.set(joined, for: .voiceInputLanguages) }
    }
}

extension EngineCapabilityProfile {
    /// FR17.15 六语种清单：**派生自 dialectMatrix()**（单一事实源，ADR-027——
    /// 禁止在本视图另建一套语种表，能力画像与选择器必须同源）。
    /// nativeName 为该语言原文（T2 后缀「·尽力识别」与徽标叠加展示）。
    static var sixLanguages: [(locale: String, nativeName: String, tier: Tier)] {
        dialectMatrix().map { profile in
            (profile.supportedLocales.first?.identifier ?? profile.capabilityID,
             profile.notes ?? profile.capabilityID,
             profile.tier)
        }
    }
}
