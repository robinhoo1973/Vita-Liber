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
    @State private var indexFailed = false

    private let service = ASRModelDownloadService.shared

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    var body: some View {
        Section {
            // 安全审查 2026-09-12：索引拉取改为「检查更新」显式按钮触发——
            // 此前区块出现即自动 GET（reloadIgnoringLocalCacheData）属契约外
            // 隐式联网面（零隐式联网红线的唯一例外必须显式发起）。
            Button {
                Task { await refreshIndex() }
            } label: {
                Label(L10n.asrModelCheckUpdate, systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(busy != nil)
            .accessibilityIdentifier("\(accessibilityPrefix).model.checkUpdate")

            if indexFailed {
                Text(L10n.asrIndexFetchFailed)
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("\(accessibilityPrefix).model.indexFailed")
            }

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

    /// 「检查更新」按钮显式触发（安全审查 2026-09-12）：每次点击都真实重拉；
    /// 失败显示可见文案（indexFailed）并可重试，无终身禁用态。成功即缓存于 @State。
    private func refreshIndex() async {
        do {
            index = try await service.fetchIndex(from: ASRModelDownloadService.indexURL)
            indexFailed = false
        } catch {
            // 拉取失败保留旧索引（若有）：更新/下载按钮仍可用；失败标记驱动可见文案。
            indexFailed = true
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
