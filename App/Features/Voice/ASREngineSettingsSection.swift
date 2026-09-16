import SwiftUI
import Domain
import Infrastructure
import Perception
#if os(iOS)
import UIKit   // beginBackgroundTask（切后台继续下载窗口）
#endif

/// FR17.15 生产设置：选择直接写入 voiceEngine，下一次按压从同一键解析。
/// 业主 2026-09-12 决定：随包模型之外新增**运行时下载路径**——
/// 本区块负责「检查更新 / 下载 / 更新 + 进度 + 失败可重试」；识别会话路径绝不联网。
///
/// 2026-09-16 业主实测修复批（语音下载体验）：
/// - **阶段进度**：下载后的校验/解压/安装/清理此前完全无反馈（用户判定「卡死」）——
///   接入 `InstallPhase`，下载显示分数进度 + 字节数字（慢链路下条位移缓慢，数字给确定反馈），
///   后续阶段显示不确定进度 + 阶段文案；
/// - **多任务**：此前单 `busy` 全局互斥，第二个下载被静默拒绝——改 per-choice 进行态集合
///   （服务端已按 per-model 互斥 + 并发上限 2）；
/// - **切后台**：`beginBackgroundTask` 窗口（系统 ~30min），文案相应更新；
/// - **检查更新三元反馈**：检查中 / 已是最新 / 发现 N 个可更新 / 失败（此前点击无任何结果）；
/// - **资产失效广播**：安装成功 `assetsChanged()`——语言列表据此重算可选性
///   （此前同页内下载完成不触发重算，「下载完了还是不能选」）。
struct ASREngineSettingsSection: View {
    @Environment(AppSettingsStore.self) private var settings
    /// 安装中心（App 层，2026-09-16 提升）：进行态在此**全局可见**（首页同源），
    /// 离开设置页不再丢失；本页只自持索引与检查状态。
    @Environment(ASRInstallCenter.self) private var installCenter
    var accessibilityPrefix = "SP-25"

    /// 「检查更新」三元结果（业主实测：此前点击无任何可见反馈）。
    private enum IndexCheckState: Equatable {
        case idle, checking, upToDate, updates(Int), failed
    }

    @State private var index: ASRModelReleaseIndex?
    @State private var checkState: IndexCheckState = .idle

    private let service = ASRModelDownloadService.shared

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    var body: some View {
        WithPerceptionTracking {
            Section {
                // 安全审查 2026-09-12：索引拉取改为「检查更新」显式按钮触发——
                // 此前区块出现即自动 GET（reloadIgnoringLocalCacheData）属契约外
                // 隐式联网面（零隐式联网红线的唯一例外必须显式发起）。
                Button {
                    Task { await refreshIndex() }
                } label: {
                    HStack {
                        Label(L10n.asrModelCheckUpdate, systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if checkState == .checking { ProgressView().controlSize(.small) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(checkState == .checking)
                .accessibilityIdentifier("\(accessibilityPrefix).model.checkUpdate")

                // 检查结果三元反馈（进行中由按钮内 spinner 承担）
                switch checkState {
                case .upToDate:
                    Text(L10n.asrModelCheckUpToDate)
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(accessibilityPrefix).model.checkUpToDate")
                case .updates(let count):
                    Text(L10n.asrModelCheckUpdates(count))
                        .font(.caption).foregroundStyle(Color("brand-primary", bundle: .main))
                        .accessibilityIdentifier("\(accessibilityPrefix).model.checkUpdates")
                case .failed:
                    Text(L10n.asrIndexFetchFailed)
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("\(accessibilityPrefix).model.indexFailed")
                case .idle, .checking:
                    EmptyView()
                }

                ForEach(VoiceEngineChoice.allCases, id: \.self) { choice in
                    // ForEach 行闭包逃逸：行内同步读感知对象属性，须自行包裹（子项目 I）
                    WithPerceptionTracking {
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
                }
            } header: { Text(L10n.voiceLabEngineSection) }
              footer: { Text(L10n.asrSelectionHint) }
        }
    }

    // MARK: - 运行时下载（FR17.15 业主 2026-09-12 决定）

    @ViewBuilder
    private func downloadControls(_ choice: VoiceEngineChoice) -> some View {
        let installed = ASRModelDownloadService.installedVersion(for: choice)
        let availableIndex = index ?? ModelCatalogTrustStore.shared.currentIndex ?? ModelCatalogTrustStore.shared.baselineIndex
        let latest = availableIndex.flatMap {
            ASRModelDownloadService.latest(for: choice, in: $0, appVersion: appVersion)
        }
        let update = availableIndex.flatMap {
            ASRModelDownloadService.updateAvailable(for: choice, index: $0, appVersion: appVersion)
        }
        VStack(alignment: .leading, spacing: 4) {
            if let installed {
                Text(L10n.asrModelInstalled(installed))
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(accessibilityPrefix).model.installed.\(choice.rawValue)")
            }
            if let active = installCenter.install(choice) {
                installProgress(choice, active)
            } else {
                if installCenter.failed.contains(choice) {
                    // 失败提示与重试按钮并存：此前失败态被更新/下载按钮分支
                    // 永远遮蔽（分支顺序 bug），下载失败完全无反馈。
                    Text(L10n.asrModelDownloadFailed)
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("\(accessibilityPrefix).model.failed.\(choice.rawValue)")
                }
                if let update {
                    Button(L10n.asrModelUpdate(update.version)) { startInstall(update) }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                        .accessibilityIdentifier("\(accessibilityPrefix).model.update.\(choice.rawValue)")
                } else if let latest, installed == nil {
                    Button(L10n.asrModelDownload) { startInstall(latest) }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                        .accessibilityIdentifier("\(accessibilityPrefix).model.download.\(choice.rawValue)")
                }
            }
        }
    }

    /// 进行态视图：下载 = 分数进度 + 字节数字（慢链路下条位移缓慢，数字给确定反馈）；
    /// 校验/解压/安装/清理 = 不确定进度 + 阶段文案（此前这些阶段完全无反馈）。
    @ViewBuilder
    private func installProgress(_ choice: VoiceEngineChoice, _ active: ASRInstallCenter.Install) -> some View {
        if let progress = active.progress, active.phase == .downloading {
            ProgressView(value: progress.fraction).frame(maxWidth: 260)
            Text(L10n.asrModelProgress(
                ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)))
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("\(accessibilityPrefix).model.progress.\(choice.rawValue)")
        } else {
            ProgressView().frame(maxWidth: 260)
            Text(phaseText(active.phase))
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("\(accessibilityPrefix).model.phase.\(choice.rawValue)")
        }
        Text(L10n.asrModelBackgroundHint)
            .font(.caption2).foregroundStyle(.tertiary)
        Button(L10n.commonCancel) { installCenter.cancel(choice) }
            .frame(minHeight: 44)
            .accessibilityIdentifier("\(accessibilityPrefix).model.cancel.\(choice.rawValue)")
    }

    private func phaseText(_ phase: ASRModelDownloadService.InstallPhase?) -> String {
        switch phase {
        case .verifying: return L10n.asrModelPhaseVerifying
        case .unpacking: return L10n.asrModelPhaseUnpacking
        case .activating: return L10n.asrModelPhaseActivating
        case .pruning: return L10n.asrModelPhasePruning
        case .downloading, nil: return L10n.asrModelDownloading
        }
    }

    /// 「检查更新」按钮显式触发（安全审查 2026-09-12）：每次点击都真实重拉；
    /// 结果三元反馈（2026-09-16）：已是最新 / 发现 N 个可更新 / 失败可重试。
    private func refreshIndex() async {
        checkState = .checking
        do {
            let fetched = try await service.fetchIndex(from: ASRModelDownloadService.indexURL)
            index = fetched
            // 该索引下、与本 App 版本兼容且已授权的新装/更新条目数。
            let count = VoiceEngineChoice.allCases.reduce(into: 0) { total, choice in
                let latest = ASRModelDownloadService.latest(for: choice, in: fetched, appVersion: appVersion)
                let update = ASRModelDownloadService.updateAvailable(for: choice, index: fetched, appVersion: appVersion)
                let isNewInstall = latest != nil && ASRModelDownloadService.installedVersion(for: choice) == nil
                if update != nil || isNewInstall { total += 1 }
            }
            checkState = count > 0 ? .updates(count) : .upToDate
        } catch {
            // 拉取失败保留旧索引（若有）：更新/下载按钮仍可用。
            checkState = .failed
        }
    }

    private func startInstall(_ release: ASRModelRelease) {
        let base = (index ?? ModelCatalogTrustStore.shared.baselineIndex)?.baseUrl.flatMap(URL.init(string:))
        // 启动/取消/进度/后台窗口/资产广播全在中心（App 层）——本页只提供索引与授权上下文。
        installCenter.start(release, baseURL: base)
    }
}
