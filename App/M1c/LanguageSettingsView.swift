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
@MainActor
struct VoiceLanguageSettingsView: View {
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    /// FR17.15 V3.61：**有序**列表——首位 = 主语言（识别 locale）；此前 Set + sorted()
    /// 字母序写回，多选 {普通话, 英语} 实际主语言变成 en-US
    @State private var inputLangs: [String] = []
    @State private var inputCapability = TranscriptionCapability.baseline(locales: [])
    @State private var loaded = false

    private var outputLang: String {
        app.voiceOutputLocale
    }

    @State private var t2Explained: T2Info?

    /// T2 说明卡载体（Identifiable 供 sheet(item:)）
    private struct T2Info: Identifiable {
        let locale: String
        let nativeName: String
        var id: String { locale }
    }

    var body: some View {
        List {
            Section {
                ForEach(EngineCapabilityProfile.sixLanguages, id: \.locale) { lang in
                    let resolved = inputCapability.resolvedLocale(for: lang.locale)
                    HStack {
                        Button {
                            toggleInput(lang.locale)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lang.nativeName)
                                    if let resolved,
                                       TranscriptionLocale.normalizedIdentifier(resolved)
                                        != TranscriptionLocale.normalizedIdentifier(lang.locale) {
                                        Text(L10n.voiceRecognizedAs(resolved))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                if TranscriptionLocale.normalizedIdentifier(inputLangs.first ?? "")
                                    == TranscriptionLocale.normalizedIdentifier(lang.locale) {
                                    Text(L10n.voicePrimaryLanguage)
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color("brand-primary", bundle: .main).opacity(0.15)))
                                        .foregroundStyle(Color("brand-primary", bundle: .main))
                                        .accessibilityIdentifier("SP-25.voiceInputLang.primary")
                                }
                                if lang.tier == .bestEffort || (resolved != nil && inputCapability.locale(matching: lang.locale) == nil) {
                                    Text(L10n.voiceLangBestEffort)
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color(.systemGray5)))
                                }
                                Spacer()
                                if inputLangs.contains(where: {
                                    TranscriptionLocale.normalizedIdentifier($0) == TranscriptionLocale.normalizedIdentifier(lang.locale)
                                }) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color("brand-primary", bundle: .main))
                                }
                                if loaded && resolved == nil { Image(systemName: "mic.slash") }
                            }
                        }
                        .disabled(!loaded || resolved == nil)
                        .accessibilityIdentifier("SP-25.voiceInputLang.\(lang.locale)")
                        if lang.tier == .bestEffort {
                            Button {
                                t2Explained = T2Info(locale: lang.locale, nativeName: lang.nativeName)
                            } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.voiceLangT2Title(lang.nativeName))
                        }
                    }
                }
            } header: {
                Text(L10n.voiceLangInputSection)
            } footer: {
                Text(L10n.voiceLangInputHint + "\n" + L10n.voicePrimaryLanguageHint)
                if loaded && inputCapability.availableLocales.isEmpty { Text(L10n.voiceInputUnavailable) }
            }

            // One selected primary recognizer plus phrase bias, not sequential multilingual recognition.
            Section {
                Toggle(L10n.voiceLangMixedToggle, isOn: Binding(
                    get: { settings.values[.voiceMixedInput] != "false" },
                    set: { on in Task { await settings.set(on ? "true" : "false", for: .voiceMixedInput) } }
                ))
                .accessibilityIdentifier("SP-25.voiceMixedInput.toggle")
            } footer: {
                Text(L10n.voiceLangMixedHint)
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
        .sheet(item: $t2Explained) { lang in
            T2ExplanationSheet(locale: lang.locale, nativeName: lang.nativeName)
        }
        .navigationTitle(L10n.voiceLangTitle)
        .task { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { inputCapability = await app.transcriptionEngine.currentCapability() }
            }
        }
    }

    private func load() async {
        // 第六轮全仓审查修复（写前读竞态）：必须先等 settings.load()——
        // 原实现直接读 values（可能为空）回落默认单语言，用户首次切换
        // 即把已存的多语言集合重写为 {默认, 新选}，其余语种静默丢失
        await settings.load()
        inputLangs = SettingsRules.voiceLocales(settings.values[.voiceInputLanguages])
        inputCapability = await app.transcriptionEngine.currentCapability()
        loaded = true
    }

    /// 点未选 = 追加到末尾；点已选且非主语言 = 提升为主语言；点主语言 = 取消（至少保留一项）。
    /// 存储保序（首位即主语言，Domain SettingsRules.voiceLocales 同源解析）。
    private func toggleInput(_ locale: String) {
        guard inputCapability.resolvedLocale(for: locale) != nil else { return }
        if let index = inputLangs.firstIndex(where: {
            TranscriptionLocale.normalizedIdentifier($0) == TranscriptionLocale.normalizedIdentifier(locale)
        }) {
            if index == 0 {
                // 至少启用一项（FR17.15：全部关闭时入口置灰并引导恢复默认）
                guard inputLangs.count > 1 else { return }
                inputLangs.removeFirst()
            } else {
                inputLangs.remove(at: index)
                inputLangs.insert(locale, at: 0)
            }
        } else {
            inputLangs.append(locale)
        }
        let joined = inputLangs.joined(separator: ",")
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

/// T2 means Mandarin-baseline best effort and mandatory review, not a dialect vocabulary claim.
@MainActor
struct T2ExplanationSheet: View {
    let locale: String
    let nativeName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Text(L10n.voiceLangT2Title(nativeName)).font(.headline)
                Label(L10n.voiceLangT2Point1, systemImage: "ear")
                Label(L10n.voiceLangT2Point3, systemImage: "checkmark.seal")
            }
            .navigationTitle(L10n.voiceLangBestEffort)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.onboard_gotIt) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
