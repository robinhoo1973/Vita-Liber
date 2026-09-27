import SwiftUI
import UIKit
import Domain
import Infrastructure
import Perception

/// 统一「模型与数据资源」管理页（SP-64，2026-09-27 业主定案 + 委员会 UX 席 B 形态）：
/// 所有可下载/更新资源一处管理——活动任务聚合置顶（空闲零痕迹）、资源清单每行
/// 状态 + 版本 + 行内进度 + 操作；后台进度仍走系统通道（iOS 26 已接线）。
/// B2-1 骨架：目录面（本地状态只读）+ T2 随包只读 + ASR 只读状态；更新流在 B2-3。
struct ResourceManagementView: View {
    @Environment(AppState.self) private var app
    @Environment(ASRInstallCenter.self) private var installCenter
    @Environment(MedicalCatalogState.self) private var catalogState

    var body: some View {
        WithPerceptionTracking {
            Form {
                activeSection
                resourcesSection
            }
            .navigationTitle(L10n.resourceManagementTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// 进行中任务（仅在存在时出现——空闲零痕迹纪律）。
    @ViewBuilder
    private var activeSection: some View {
        if !installCenter.active.isEmpty {
            Section(L10n.resourceActiveTitle) {
                ForEach(installCenter.active, id: \.id) { install in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L10n.voiceEngineName(install.choice))
                                .font(.subheadline)
                            Spacer()
                            Text(phaseText(install.phase))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let progress = install.progress, progress.totalBytes > 0 {
                            ProgressView(value: progress.fraction)
                            HStack {
                                Text(byteText(progress.receivedBytes, progress.totalBytes))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(L10n.commonCancel) { installCenter.cancel(install.choice) }
                                    .font(.caption)
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("SP-64.resource.cancel.\(install.choice.rawValue)")
                            }
                        } else {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("SP-64.resource.active.\(install.choice.rawValue)")
                }
            }
        }
    }

    // MARK: - SP-64 医疗目录维护（B2-3）

    /// 医疗数据目录维护段：本地状态常显、显式检查 → 独立更新（FR25.13 零隐式联网——
    /// 只有用户点按钮才触发网络）；失败/取消保留本机 last-good。
    /// VoiceOver 播报纪律（§5.12.4）：只在阶段切换/完成/失败播报，不逐字节播报。
    private var catalogSection: some View {
        Section {
            // 本地状态（与远端检查态分离——断网/限流/失败时本机目录仍可见可用）
            LabeledContent(L10n.resourceCatalogLocalLabel) {
                if let version = catalogState.localVersion {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(L10n.resourceCatalogLocalVersionFmt(String(version.dataVersion.prefix(8))))
                        if let updatedAt = catalogState.localUpdatedAt {
                            Text(L10n.resourceCatalogLocalUpdatedFmt(localTimeText(updatedAt)))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(L10n.resourceCatalogNotAvailable)
                        .font(.caption)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                }
            }
            .accessibilityIdentifier("SP-64.medicalCatalog.local")

            remoteRow

            // 一次性成功事件（§5.12.4「成功才展示更新完成及新本地版本」）
            if let completed = catalogState.updateCompletedDataVersion {
                Label(L10n.resourceCatalogUpdateCompletedFmt(String(completed.prefix(8))),
                      systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .accessibilityIdentifier("SP-64.medicalCatalog.completed")
            }

            if let progress = catalogState.updateProgress {
                updateProgressRow(progress)
            }
            if let error = catalogState.updateError {
                Text(updateErrorText(error))
                    .font(.footnote)
                    .foregroundStyle(Color("semantic-warning", bundle: .main))
                    .accessibilityIdentifier("SP-64.medicalCatalog.updateError")
            }
        } header: {
            Text(L10n.resourceCatalogRow)
        } footer: {
            Text(L10n.resourceCatalogPrivacy)
        }
        .onChangeCompat(of: catalogUpdatePhaseKey) { _, _ in
            if let progress = catalogState.updateProgress {
                UIAccessibility.post(notification: .announcement, argument: catalogPhaseText(progress))
            }
        }
        .onChangeCompat(of: catalogState.updateCompletedDataVersion) { _, version in
            if let version {
                UIAccessibility.post(notification: .announcement,
                                     argument: L10n.resourceCatalogUpdateCompletedFmt(String(version.prefix(8))))
            }
        }
        .onChangeCompat(of: catalogState.updateError) { _, error in
            if let error {
                UIAccessibility.post(notification: .announcement, argument: updateErrorText(error))
            }
        }
    }

    /// 阶段键（无关联值的稳定形态）：只播报阶段切换，下载字节变化不触发播报。
    private var catalogUpdatePhaseKey: String {
        guard let progress = catalogState.updateProgress else { return "idle" }
        switch progress {
        case .downloading: return "downloading"
        case .verifyingPackage: return "verifyingPackage"
        case .decrypting: return "decrypting"
        case .verifyingCatalog: return "verifyingCatalog"
        case .activating: return "activating"
        }
    }

    @ViewBuilder
    private var remoteRow: some View {
        switch catalogState.remoteState {
        case .idle:
            catalogActionButton(L10n.resourceCatalogCheck, id: "check") { catalogState.check() }
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text(L10n.resourceCatalogChecking)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.commonCancel) { catalogState.cancelCheck() }
                    .font(.caption)
                    .frame(minHeight: 44)
                    .accessibilityHint(L10n.resourceCatalogCancelCheckHint)
                    .accessibilityIdentifier("SP-64.medicalCatalog.cancelCheck")
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SP-64.medicalCatalog.status")
        case .upToDate:
            catalogStatusRow(L10n.resourceCatalogUpToDate, id: "status.upToDate", systemImage: "checkmark.circle")
        case .updateAvailable(let candidate):
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.resourceCatalogUpdateAvailableFmt(candidate.catalogVersion),
                      systemImage: "arrow.down.circle")
                    .font(.subheadline)
                    .accessibilityIdentifier("SP-64.medicalCatalog.status")
                Text(L10n.resourceCatalogCandidateDetailFmt(
                    String(candidate.dataVersion.prefix(8)),
                    ByteCountFormatter.string(fromByteCount: candidate.packageSize, countStyle: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    catalogState.applyUpdate()
                } label: {
                    Text(L10n.resourceCatalogUpdate)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(catalogState.isUpdating)
                .accessibilityHint(L10n.resourceCatalogUpdateHint)
                .accessibilityIdentifier("SP-64.medicalCatalog.update")
                catalogActionButton(L10n.resourceCatalogRecheck, id: "recheck") { catalogState.check() }
            }
        case .noInstallableAvailable:
            catalogStatusRow(L10n.resourceCatalogNoInstallable, id: "status.noInstallable", systemImage: "info.circle")
        case .unavailable:
            catalogStatusRow(L10n.resourceCatalogUnavailable, id: "status.unavailable", systemImage: "tray")
        case .rateLimited(let retryAfter):
            catalogStatusRow(retryLimitedText(retryAfter), id: "status.rateLimited", systemImage: "clock")
        case .verificationFailed:
            catalogStatusRow(L10n.resourceCatalogVerificationFailed, id: "status.verificationFailed",
                             systemImage: "exclamationmark.triangle", warning: true)
        case .networkUnavailable:
            catalogStatusRow(L10n.resourceCatalogNetworkUnavailable, id: "status.networkUnavailable", systemImage: "wifi.slash")
        }
    }

    /// 状态行（图标 + 文案）+ 边框「重新检查」（检查与更新是分离的两个显式动作）。
    private func catalogStatusRow(_ text: String, id: String, systemImage: String? = nil,
                                  warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                }
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(warning
                        ? AnyShapeStyle(Color("semantic-warning", bundle: .main))
                        : AnyShapeStyle(.secondary))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("SP-64.medicalCatalog.\(id)")
            catalogActionButton(L10n.resourceCatalogRecheck, id: "recheck") { catalogState.check() }
        }
    }

    private func catalogActionButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .disabled(catalogState.isUpdating)
        .accessibilityHint(L10n.resourceCatalogCheckHint)
        .accessibilityIdentifier("SP-64.medicalCatalog.\(id)")
    }

    private func updateProgressRow(_ progress: MedicalCatalogDownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(catalogPhaseText(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // 切换阶段开始后安装器不再响应取消（journal 契约）——隐藏取消按钮
                if catalogState.canCancelUpdate {
                    Button(L10n.commonCancel) { catalogState.cancelUpdate() }
                        .font(.caption)
                        .frame(minHeight: 44)
                        .accessibilityHint(L10n.resourceCatalogCancelHint)
                        .accessibilityIdentifier("SP-64.medicalCatalog.cancel")
                }
            }
            switch progress {
            case .downloading(let received, let total):
                ProgressView(value: total > 0 ? Double(received) / Double(total) : 0)
                Text(byteText(received, total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityValue(percentText(progress) ?? "")
        .accessibilityIdentifier("SP-64.medicalCatalog.progress")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// 进度百分比（无障碍 value）：颜色/进度条不是唯一状态信号，数字随读。
    private func percentText(_ progress: MedicalCatalogDownloadProgress) -> String? {
        guard case .downloading(let received, let total) = progress, total > 0 else { return nil }
        return "\(received * 100 / total)%"
    }

    private func catalogPhaseText(_ progress: MedicalCatalogDownloadProgress) -> String {
        switch progress {
        case .downloading: return L10n.resourceCatalogPhaseDownloading
        case .verifyingPackage: return L10n.resourceCatalogPhaseVerifyingPackage
        case .decrypting: return L10n.resourceCatalogPhaseDecrypting
        case .verifyingCatalog: return L10n.resourceCatalogPhaseVerifyingCatalog
        case .activating: return L10n.resourceCatalogPhaseActivating
        }
    }

    /// 更新错误 → 用户文案：安全事件（回退拒绝）与可行动指引（存储不足）单列，
    /// 其余保留通用「更新失败，本机目录仍可用」（13 词折叠评审修复）。
    private func updateErrorText(_ error: MedicalCatalogDownloadError) -> String {
        switch error {
        case .cancelled: return L10n.resourceCatalogUpdateCancelled
        case .insufficientStorage: return L10n.resourceCatalogFailedStorage
        case .catalogRolledBack: return L10n.resourceCatalogFailedRolledBack
        default: return L10n.resourceCatalogUpdateFailed
        }
    }

    /// 限流可重试时间：App 内语言 locale（L10n.bundleLanguage）+ 过期守护（
    /// 已过可重试时间只呈限流事实，避免「…前」逆文案）；无时间信息只呈限流事实。
    private func retryLimitedText(_ retryAfter: Date?) -> String {
        guard let retryAfter, retryAfter > Date() else { return L10n.resourceCatalogRateLimited }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: L10n.bundleLanguage)
        let relative = formatter.localizedString(for: retryAfter, relativeTo: Date())
        return L10n.resourceCatalogRateLimitedFmt(relative)
    }

    /// 本地更新时间：App 内语言 locale 的短日期+时间。
    private func localTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.bundleLanguage)
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var resourcesSection: some View {
        Section(L10n.resourceCatalogTitle) {
            catalogSection

            // T2 本地模型（随包内置，不可更新——诚实展示）
            HStack {
                Label(L10n.resourceT2Row, systemImage: "brain")
                Spacer()
                Text(L10n.resourceBundled)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("SP-64.resource.t2")

            // ASR 语音模型：状态只读，管理入口在语音设置（B2-3 并入本页）
            ForEach(VoiceEngineChoice.allCases, id: \.self) { choice in
                HStack {
                    Label(L10n.voiceEngineName(choice), systemImage: "waveform")
                    Spacer()
                    if let version = ASRModelDownloadService.installedVersion(for: choice) {
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if choice.isBundledModel {
                        Text(L10n.resourceBundled)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.resourceNotInstalled)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("SP-64.resource.asr.\(choice.rawValue)")
            }
        }
    }

    private func phaseText(_ phase: ASRModelDownloadService.InstallPhase?) -> String {
        guard let phase else { return L10n.resourcePhaseWaiting }
        switch phase {
        case .downloading: return L10n.resourcePhaseDownloading
        case .verifying: return L10n.resourcePhaseVerifying
        case .unpacking: return L10n.resourcePhaseUnpacking
        case .activating: return L10n.resourcePhaseActivating
        case .pruning: return L10n.resourcePhasePruning
        }
    }

    /// 可读字节（ByteCountFormatter，ASR 进度先例；「103648322 / 511923688」不可读，
    /// 评审修复 2026-09-27）。
    private func byteText(_ received: Int64, _ total: Int64) -> String {
        L10n.resourceProgressBytes(
            ByteCountFormatter.string(fromByteCount: received, countStyle: .file),
            ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
    }
}
