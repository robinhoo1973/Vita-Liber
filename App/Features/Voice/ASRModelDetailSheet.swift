import SwiftUI
import Domain
import Infrastructure
import Perception

/// 模型详情页（2026-10-06 业主反馈批第 3 项：点按下载卡片子卡 → 单独显示该下载
/// 模型的详细信息页）：家族文案/档位参数/已装状态/当前任务与操作一处呈现。
///
/// 位置纪律：sheet 由首页就地弹出（不经路由注册表——详情不是 SP 页面，弹出不切
/// Tab、不压管理页栈）；页内保留「模型与数据资源」入口（管理面仍在 SP-64）。
/// 滑动式卡片动作在此有显式按钮兜底（滑动手势对震颤/VoiceOver 用户不可达，
/// 关怀模式触点 ≥64pt 同源 `AppState.careMode`）。
///
/// 观察域：任务区读 `installCenter` 的进度（5 Hz）——本 sheet 独占一屏，高频进度
/// 只重算本页，不牵连首页全量聚合（与 HomeModelDownloadCard 同纪律）。
struct ASRModelDetailSheet: View {
    let choice: VoiceEngineChoice

    @Environment(ASRInstallCenter.self) private var installCenter
    @Environment(AppRouter.self) private var router
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// 目录派生信息（`.task` 一次算好；渲染路径不取信任库锁——与
    /// `ASREngineSettingsSection` 的主线程加固同纪律）。
    private struct Info: Sendable {
        var name: String?
        var hint: String?
        var license: String?
        var variants: [ASRModelRelease] = []
        var installedVersion: String?
        var installedVariant: String?
    }
    @State private var info = Info()

    private var touchTarget: CGFloat { app.careMode ? 64 : 44 }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                List {
                    summarySection
                    taskSection
                    tiersSection
                    installedSection
                    manageSection
                }
                .navigationTitle(L10n.asrModelDetailTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.commonClose) { dismiss() }
                            .frame(minHeight: touchTarget)
                            .accessibilityIdentifier("SP-04.modelDetail.close")
                    }
                }
                .task { await load() }
            }
        }
    }

    // MARK: - 概要

    @ViewBuilder
    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.name ?? L10n.voiceEngineName(choice))
                    .font(.headline)
                Text(info.hint ?? L10n.voiceEngineHint(choice))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(minHeight: touchTarget)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("SP-04.modelDetail.summary")
        }
    }

    // MARK: - 当前任务（进行中/暂停；完成行可隐藏）

    @ViewBuilder
    private var taskSection: some View {
        if let install = installCenter.install(choice) {
            Section(L10n.asrModelDetailTask) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(taskStatusText(install))
                        .font(.subheadline)
                    if let progress = install.progress,
                       install.isPaused || install.phase == .downloading {
                        ProgressView(value: progress.fraction)
                        Text(L10n.asrModelProgress(
                            ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file),
                            ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    taskActionButtons(install)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SP-04.modelDetail.task")
            }
        } else if let finished = installCenter.finished.first(where: { $0.choice == choice }) {
            Section(L10n.asrModelDetailTask) {
                Text(L10n.asrModelPhaseCompleted)
                    .font(.subheadline)
                Button(L10n.homeModelDownloadHide) { installCenter.removeFinished(finished.choice) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: touchTarget)
                    .accessibilityIdentifier("SP-04.modelDetail.hide")
            }
        }
    }

    @ViewBuilder
    private func taskActionButtons(_ install: ASRInstallCenter.Install) -> some View {
        HStack(spacing: 12) {
            if install.isPaused {
                Button(L10n.homeModelDownloadResume) { installCenter.resume(choice) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: touchTarget)
                    .accessibilityIdentifier("SP-04.modelDetail.resume")
            } else if install.isPausable {
                Button(L10n.homeModelDownloadPause) { installCenter.pause(choice) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: touchTarget)
                    .accessibilityIdentifier("SP-04.modelDetail.pause")
            }
            Button(L10n.commonCancel, role: .destructive) { installCenter.cancel(choice) }
                .buttonStyle(.bordered)
                .frame(minHeight: touchTarget)
                .accessibilityIdentifier("SP-04.modelDetail.cancel")
        }
    }

    private func taskStatusText(_ install: ASRInstallCenter.Install) -> String {
        if install.isFinished { return L10n.asrModelPhaseCompleted }
        if install.isPaused { return L10n.asrModelPaused }
        if install.waiting { return L10n.asrModelQueued }
        return L10n.asrPhaseText(install.phase)
    }

    // MARK: - 档位

    @ViewBuilder
    private var tiersSection: some View {
        if !info.variants.isEmpty {
            Section(L10n.asrModelDetailTiers) {
                // id: \.variant（同选择器修复：家族 id 非唯一，档位键才唯一）。
                ForEach(info.variants, id: \.variant) { variant in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.asrTierDisplayName(variant.variant, in: info.variants))
                                .font(.subheadline)
                            Text(L10n.asrModelVariantDetail(
                                L10n.asrModelBytes(variant.bytes ?? 0),
                                L10n.asrModelBytes(variant.expandedBytes ?? 0),
                                L10n.asrModelBytes(ModelMemoryBudget.peakBytes(modelBytes: variant.expandedBytes ?? 0))))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if variant.variant == info.installedVariant {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color("brand-primary", bundle: .main))
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: touchTarget)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("SP-04.modelDetail.tier.\(variant.variant ?? "unknown")")
                }
            }
        }
    }

    // MARK: - 已安装

    @ViewBuilder
    private var installedSection: some View {
        if let version = info.installedVersion {
            Section(L10n.asrModelDetailInstalled) {
                HStack {
                    Text(L10n.asrModelInstalled(version))
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    if let installedVariant = info.installedVariant {
                        Text(L10n.asrTierDisplayName(installedVariant, in: info.variants))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: touchTarget)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("SP-04.modelDetail.installed")
                if let license = info.license {
                    Text(license)
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("SP-04.modelDetail.license")
                }
            }
        }
    }

    // MARK: - 管理入口

    private var manageSection: some View {
        Section {
            Button {
                dismiss()
                router.navigate(to: .resourceManagement)
            } label: {
                Label(L10n.resourceManagementTitle, systemImage: "externaldrive")
                    .frame(minHeight: touchTarget)
            }
            .accessibilityIdentifier("SP-04.modelDetail.manage")
        }
    }

    // MARK: - 数据装载

    private func load() async {
        let target = choice
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
        let preferred = Locale.preferredLanguages
        let computed = await Task.detached(priority: .userInitiated) { () -> Info in
            let index = ModelCatalogTrustStore.shared.currentIndex
                ?? ModelCatalogTrustStore.shared.baselineIndex
            var info = Info()
            if let family = index?.family(for: target.rawValue) {
                info.name = family.name?.resolved(preferredLanguages: preferred)
                info.hint = family.hint?.resolved(preferredLanguages: preferred)
            }
            info.variants = index.map {
                ASRModelDownloadService.publishedVariants(for: target, in: $0, appVersion: version)
            } ?? []
            info.license = info.variants.first?.license
            info.installedVersion = ASRModelDownloadService.installedVersion(for: target)
            info.installedVariant = ASRModelDownloadService.installedVariant(for: target)
            return info
        }.value
        info = computed
    }
}
