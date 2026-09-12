import SwiftUI
import Domain
import Infrastructure
import Protocols

/// FR17.15 V3.66 识别引擎实验室（SP-62）：引擎档位选择 + 语言资源安装 + 听写对照测试。
///
/// 设计纪律（tech-spec §1.1 规则 4）：本页只做「呈现 + 测试」——引擎构建、可用性探测、
/// 资源状态一律经 `TranscriptionEngineBuilder` 与 `TranscriptionEngine` 协议出口，
/// 视图层零业务判断、零具体引擎类型引用（EAL 纪律）。
///
/// 生产联动：档位写入 `AppSettingKey.voiceEngine`（AppSettingsStore 唯一写入方）——
/// 生产装配返回 `SwitchableTranscriptionEngine` 代理（复审修正 FIX-A），每次会话重读
/// 冻结键，故**切换后下一次识别**即用所选引擎（进行中的录音不受影响）。
/// 语言资源下载只在本页显式触发（离线优先红线：生产路径绝不隐式联网）。
@MainActor
struct VoiceEngineLabView: View {
    @Environment(AppSettingsStore.self) private var settings

    struct LabResult: Identifiable {
        let id = UUID()
        let text: String
        let locale: String
        let engine: VoiceEngineChoice
        let at: Date
    }

    @State private var choice: VoiceEngineChoice = .auto
    @State private var engine: (any TranscriptionEngine)?
    @State private var model: VoiceDictationModel?
    @State private var results: [LabResult] = []
    @State private var assetStatus: VoiceLocaleAssetStatus = .unavailable
    @State private var installing = false
    @State private var installNote: String?
    /// 档位代际：用户已选档后，迟到的 settings.load() 不得回写覆盖选择；
    /// 换挡前的在途 refresh/install 结果不得覆盖新档的资源状态。
    @State private var hasSelected = false
    @State private var generation = 0

    private var testLocale: String {
        SettingsRules.voiceLocales(settings.values[.voiceInputLanguages]).first
            ?? TranscriptionSegmentation.fallbackLocale
    }

    var body: some View {
        List {
            Section {
                ForEach(VoiceEngineChoice.allCases, id: \.self) { option in
                    Button { select(option) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(label(for: option))
                                Text(hint(for: option)).font(.caption).foregroundStyle(.secondary)
                                if let note = availabilityNote(for: option) {
                                    Text(note).font(.caption2)
                                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                                }
                            }
                            Spacer()
                            if option == choice {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color("brand-primary", bundle: .main))
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(model?.hasPendingTranscriptions == true)
                    .accessibilityIdentifier("SP-62.engine.\(option.rawValue)")
                }
            } header: {
                Text(L10n.voiceLabEngineSection)
            } footer: {
                Text(L10n.voiceLabEngineFooter)
            }

            Section {
                LabeledContent(L10n.voiceLabLocaleLabel, value: testLocale)
                LabeledContent(L10n.voiceLabAssetLabel, value: assetLabel)
                if assetStatus == .downloadable {
                    Button { install() } label: {
                        Label(installing ? L10n.voiceLabInstalling : L10n.voiceLabInstall,
                              systemImage: "arrow.down.circle")
                            .frame(minHeight: 44)
                    }
                    .disabled(installing)
                    .accessibilityIdentifier("SP-62.asset.install")
                }
                if let installNote {
                    Text(installNote).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("SP-62.asset.note")
                }
            } header: {
                Text(L10n.voiceLabAssetSection)
            } footer: {
                Text(L10n.voiceLabAssetFooter)
            }

            Section {
                if let model {
                    PressToTalkMicButton(model: model)
                        .disabled(installing)
                    if let resolved = model.resolvedLocale {
                        Text(L10n.voiceRecognizedAs(resolved))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    // 复审修正 FIX-B（2026-09-11）：诚实标注「所选档位是否真在服务」——
                    // 资源未装/系统不足时平台轨会整会话回落基线轨，若不提示，
                    // 用户会把基线结果当成所选引擎的识别率（对照实验失去意义）。
                    if let note = testFallbackNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(Color("semantic-warning", bundle: .main))
                            .accessibilityIdentifier("SP-62.test.fallbackNote")
                    }
                }
            } header: {
                Text(L10n.voiceLabTestSection)
            } footer: {
                Text(L10n.voiceLabTestFooter)
            }

            Section {
                if results.isEmpty {
                    Text(L10n.voiceLabNoResult).foregroundStyle(.secondary)
                } else {
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.text)
                            Text(metaLine(result))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .onDelete { results.remove(atOffsets: $0) }
                }
            } header: {
                Text(L10n.voiceLabResultSection)
            } footer: {
                Text(L10n.voiceLabResultFooter)
            }
        }
        .navigationTitle(L10n.voiceLabTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await settings.load()
            // 审查修复：仅当用户尚未手动选档时才用持久化值初始化——旧实现
            // 无条件覆盖，装载在途期间的点击被静默丢弃且 rebuild 重建测试模型。
            if !hasSelected {
                choice = VoiceEngineChoice.resolve(settings.values[.voiceEngine])
                rebuild()
                await refreshAssetStatus()
            }
        }
        .onChange(of: settings.values[.voiceInputLanguages]) { _, _ in
            rebuild()
            Task { await refreshAssetStatus() }
        }
        .onDisappear { model?.stopForDisappear() }
    }

    private func select(_ option: VoiceEngineChoice) {
        guard option != choice, model?.hasPendingTranscriptions != true else { return }
        choice = option
        hasSelected = true
        generation += 1
        Task { await settings.set(option.rawValue, for: .voiceEngine) }
        rebuild()
        Task { await refreshAssetStatus() }
    }

    private func rebuild() {
        model?.stopForDisappear()
        let selected = choice
        let built = TranscriptionEngineBuilder.make(choice: choice)
        let created = VoiceDictationModel(engine: built, preferredLocale: testLocale)
        created.setAuthorization(settings.values[.authVoiceDictation] != "false")
        created.applyLanguageSettings(storedLocales: settings.values[.voiceInputLanguages],
                                      mixedInput: settings.values[.voiceMixedInput] != "false",
                                      recentDrugNames: [])
        created.onTranscript = { [weak created] text, _ in
            guard let created, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            results.insert(LabResult(text: text,
                                     locale: created.resolvedLocale ?? testLocale,
                                      engine: created.resolvedEngineID.flatMap(VoiceEngineChoice.init(rawValue:)) ?? selected,
                                     at: Date()), at: 0)
        }
        engine = built
        model = created
    }

    private func refreshAssetStatus() async {
        let gen = generation
        guard let engine else { assetStatus = .unavailable; return }
        let status = await engine.localeAssetStatus(testLocale)
        guard gen == generation else { return }   // 换挡后的旧状态不得覆盖新档
        assetStatus = status
    }

    /// 本次对照测试是否**不会**跑在所选引擎上（平台档回落条件：系统/设备不支持，
    /// 或该语言资源未安装）。auto 档在系统不支持时本就以基线轨为正式形态，不提示。
    private var testFallbackNote: String? {
        switch choice {
        case .classic:
            return nil
        case .qwen3, .zipformer, .dolphin, .whisper:
            // 审计修正（round3→round10）：显式选定随包模型缺件时如实报失败、
            // 不再由 builder 回落其他引擎执行（function V3.68「不得换引擎冒充」）——
            // 缺件明示文案如实告知「对照测试无法运行」，绝不声称结果来自回落引擎。
            return TranscriptionEngineBuilder.availability(of: choice) == .missingModelAssets
                ? L10n.voiceLabFallbackMissing : nil
        case .auto:
            return TranscriptionEngineBuilder.availability(of: choice) != .available
                ? nil
                : (assetStatus == .installed ? nil : L10n.voiceLabFallbackAsset)
        case .advanced, .dictation:
            if TranscriptionEngineBuilder.availability(of: choice) != .available {
                return L10n.voiceLabFallbackUnavailable
            }
            return assetStatus == .installed ? nil : L10n.voiceLabFallbackAsset
        }
    }

    private func install() {
        guard !installing, let engine else { return }
        installing = true
        installNote = nil
        let gen = generation
        Task {
            defer { installing = false }
            let ok = await engine.prepareLocale(testLocale)
            let status = await engine.localeAssetStatus(testLocale)
            guard gen == generation else { return }   // 换挡后旧安装结果不得写入新档
            assetStatus = status
            installNote = ok ? L10n.voiceLabInstallDone : L10n.voiceLabInstallFailed
        }
    }

    private func label(for option: VoiceEngineChoice) -> String {
        L10n.voiceEngineName(option)
    }

    private func hint(for option: VoiceEngineChoice) -> String {
        L10n.voiceEngineHint(option)
    }

    private func availabilityNote(for option: VoiceEngineChoice) -> String? {
        L10n.asrAvailability(TranscriptionEngineBuilder.availability(of: option))
    }

    private var assetLabel: String {
        switch assetStatus {
        case .installed: return L10n.voiceLabAssetInstalled
        case .downloadable: return L10n.voiceLabAssetDownloadable
        case .unavailable: return L10n.voiceLabAssetUnavailable
        }
    }

    private func metaLine(_ result: LabResult) -> String {
        String(format: L10n.voiceLabResultMeta,
               label(for: result.engine),
               "\(result.locale) · \(result.at.formatted(date: .omitted, time: .shortened))")
    }
}
