import SwiftUI
import Domain
import Infrastructure

/// FR17.15 生产设置：选择直接写入 voiceEngine，下一次按压从同一键解析。
/// 业主 2026-09-12 决定：随包模型之外新增**运行时下载路径**——
/// 本区块负责「检查更新 / 下载 / 更新 + 进度 + 失败可重试」；识别会话路径绝不联网。
struct ASREngineSettingsSection: View {
    @Environment(AppSettingsStore.self) private var settings
    var accessibilityPrefix = "SP-25"

    @State private var index: ASRModelReleaseIndex?
    @State private var busy: VoiceEngineChoice?
    @State private var progress: Double = 0
    @State private var failed: VoiceEngineChoice?

    private let service = ASRModelDownloadService()

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    var body: some View {
        Section {
            ForEach(VoiceEngineChoice.allCases, id: \.self) { choice in
                let availability = TranscriptionEngineBuilder.availability(of: choice)
                Button {
                    Task { await settings.set(choice.rawValue, for: .voiceEngine) }
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.voiceEngineName(choice))
                            Text(L10n.voiceEngineHint(choice)).font(.caption).foregroundStyle(.secondary)
                            if let model = ASRModelCatalog.model(for: choice) {
                                Text(model.license + " · " + L10n.asrBundledOffline)
                                    .font(.caption2).foregroundStyle(.secondary)
                                if let bytes = ASRModelAssets.resolve(for: choice).byteCount(choice) {
                                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            if let note = L10n.asrAvailability(availability) {
                                Text(note).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if VoiceEngineChoice.resolve(settings.values[.voiceEngine]) == choice {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color("brand-primary", bundle: .main))
                        }
                    }.frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(accessibilityPrefix).engine.\(choice.rawValue)")

                if choice.isBundledModel {
                    downloadControls(choice)
                }
            }
        } header: { Text(L10n.voiceLabEngineSection) }
          footer: { Text(L10n.asrSelectionHint) }
          .task { await refreshIndex() }
    }

    // MARK: - 运行时下载（FR17.15 业主 2026-09-12 决定）

    @ViewBuilder
    private func downloadControls(_ choice: VoiceEngineChoice) -> some View {
        let installed = ASRModelDownloadService.installedVersion(for: choice)
        let latest = index.flatMap {
            ASRModelDownloadService.latest(for: choice, in: $0, appVersion: appVersion)
        }
        let update = index.flatMap {
            ASRModelDownloadService.updateAvailable(for: choice, index: $0, appVersion: appVersion)
        }
        VStack(alignment: .leading, spacing: 4) {
            if let installed {
                Text(L10n.asrModelInstalled(installed))
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(accessibilityPrefix).model.installed.\(choice.rawValue)")
            }
            if busy == choice {
                ProgressView(value: progress).frame(maxWidth: 260)
                Text(L10n.asrModelDownloading)
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(accessibilityPrefix).model.progress.\(choice.rawValue)")
            } else {
                if failed == choice {
                    // 失败提示与重试按钮并存：此前失败态被更新/下载按钮分支
                    // 永远遮蔽（分支顺序 bug），下载失败完全无反馈。
                    Text(L10n.asrModelDownloadFailed)
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("\(accessibilityPrefix).model.failed.\(choice.rawValue)")
                }
                if let update {
                    Button(L10n.asrModelUpdate(update.version)) { Task { await install(update) } }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                        .accessibilityIdentifier("\(accessibilityPrefix).model.update.\(choice.rawValue)")
                } else if let latest, installed == nil {
                    Button(L10n.asrModelDownload) { Task { await install(latest) } }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                        .accessibilityIdentifier("\(accessibilityPrefix).model.download.\(choice.rawValue)")
                }
            }
        }
    }

    /// 每次区块出现重试索引拉取（此前 indexFailed 一次失败终身禁用无重试路径，
    /// 且该状态从不渲染——失败静默等于下载功能永久不可用）。成功即缓存于 @State。
    private func refreshIndex() async {
        guard index == nil else { return }
        do {
            index = try await service.fetchIndex(from: ASRModelDownloadService.indexURL)
        } catch {
            // 拉取失败保持 nil：下次出现重试（单次小 GET，不缓存写盘）。
        }
    }

    private func install(_ release: ASRModelRelease) async {
        guard busy == nil, let choice = VoiceEngineChoice(rawValue: release.id) else { return }
        busy = choice
        failed = nil
        progress = 0
        defer { busy = nil }
        let base = index?.baseUrl.flatMap(URL.init(string:))
        do {
            _ = try await service.install(release, baseURL: base) { update in
                Task { @MainActor in progress = update.fraction }
            }
        } catch {
            failed = choice
        }
    }
}
