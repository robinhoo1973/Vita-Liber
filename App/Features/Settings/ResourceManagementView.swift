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
    @Environment(LLMModelInstallCenter.self) private var llmModelInstallCenter
    @Environment(MedicalCatalogState.self) private var catalogState

    var body: some View {
        WithPerceptionTracking {
            Form {
                activeSection
                // 2026-10-07 统一更新中心批（委员会三席评审「形态 A」）：
                // 检查入口与状态语法跨域统一（ASR+医疗），安装/更新动作留域内；
                // 原独立通告区删除（呈现合并入中心，R2 边界由 Domain 规则守）。
                UpdateCenterSection()
                resourcesSection
                // B2-3（2026-09-28）：语音模型管理并入本页（检查更新/下载/进度/取消，
                // 复用语音设置页同一区块视图——单一管理面，无平行视图）。
                ASREngineSettingsSection(accessibilityPrefix: "SP-64.resource.asr")
                // 2026-10-03 信息架构评审（方案 C，ui-ux V4.12）：识别引擎实验室入口
                // 自语音语言页迁入本页——与引擎管理同域聚合，语言页只做语言选择。
                Section {
                    NavigationLink(value: AppRoute.voiceEngineLab) {
                        Label(L10n.voiceLabTitle, systemImage: "waveform")
                    }
                    .accessibilityIdentifier("SP-64.resource.engineLab.entry")
                } footer: {
                    Text(L10n.voiceLabEntryHint)
                }
            }
                        .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出（V4.13 补齐）
            .tintedCanvas()
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
                            // 2026-10-06 第 2 项：暂停态如实呈现（原实现读 phase 恒显
                            // 「下载中」——暂停后进度冻结却仍称下载中，失真）。
                            Text(install.isPaused ? L10n.asrModelPaused : phaseText(install.phase))
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
                                taskActions(install)
                            }
                        } else if install.isPaused {
                            // 排队中暂停：无字节进度可示（不给假 spinner），但动作必须
                            // 可达（2026-10-06 二轮评审：原实现此处仅 EmptyView，管理面
                            // 自己反而无法恢复/取消——与设置区块/详情页不一致）。
                            HStack {
                                Spacer()
                                taskActions(install)
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

    /// 活动任务行动作（暂停态 = 恢复 + 取消；进行态 = 取消）。
    @ViewBuilder
    private func taskActions(_ install: ASRInstallCenter.Install) -> some View {
        if install.isPaused {
            Button(L10n.homeModelDownloadResume) { installCenter.resume(install.choice) }
                .font(.caption)
                .frame(minHeight: 44)
                .accessibilityIdentifier("SP-64.resource.resume.\(install.choice.rawValue)")
        }
        Button(L10n.commonCancel) { installCenter.cancel(install.choice) }
            .font(.caption)
            .frame(minHeight: 44)
            .accessibilityIdentifier("SP-64.resource.cancel.\(install.choice.rawValue)")
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

    /// 2026-10-07 统一更新中心批（委员会裁定 D4）：检查入口与**检查态呈现**收敛到
    /// 页首「更新中心」（单一状态单渲染点）；本节只保留**更新动作闭环**——候选
    /// 详情 + [更新]（及下方进度/错误/完成行由父视图按态追加）。
    @ViewBuilder
    private var remoteRow: some View {
        if case .updateAvailable(let candidate) = catalogState.remoteState {
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
            }
        }
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

    /// 更新错误 → 用户文案：安全事件（回退拒绝）与可行动指引（存储不足/重新检查/
    /// 未配置）单列，其余保留通用「更新失败，本机目录仍可用」（13 词折叠评审修复）。
    private func updateErrorText(_ error: MedicalCatalogDownloadError) -> String {
        switch error {
        case .cancelled: return L10n.resourceCatalogUpdateCancelled
        case .insufficientStorage: return L10n.resourceCatalogFailedStorage
        case .catalogRolledBack: return L10n.resourceCatalogFailedRolledBack
        case .catalogNotConfigured: return L10n.resourceCatalogNotConfigured
        case .catalogNotInstallable: return L10n.resourceCatalogNotInstallable
        default: return L10n.resourceCatalogUpdateFailed
        }
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
            // T2 本机 LLM 模型（2026-10-09 换型+下载化批：模型不随包、运行时自
            // CNB 下载；「手动更新」= 目录版本 vs 已装版本比对——网络侧最新模型
            // 发现需签名索引，登记为后续批）。
            t2ModelRow
        }
    }

    /// T2 模型行：状态 + 行内进度 + 动作（下载/更新/删除/重试/取消）。
    /// 进度/阶段读独立观察域（`ProgressBox`）——不牵连本页其余行的重渲染。
    private var t2ModelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L10n.resourceT2Row, systemImage: "brain")
                Spacer()
                Text(t2StatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if llmModelInstallCenter.state.isBusy {
                if let fraction = llmModelInstallCenter.progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                Text(L10n.llmModelKeepForeground)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            t2Actions
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("SP-64.resource.t2")
        .task { llmModelInstallCenter.refresh() }
    }

    @ViewBuilder
    private var t2Actions: some View {
        switch llmModelInstallCenter.state {
        case .downloading, .verifying, .activating:
            Button(L10n.llmModelCancel) { llmModelInstallCenter.cancel() }
        case .installed:
            if llmModelInstallCenter.updateAvailable {
                Button(L10n.llmModelUpdate) { llmModelInstallCenter.startInstall() }
                    .buttonStyle(.borderedProminent)
            }
            Button(L10n.llmModelRemove, role: .destructive) { llmModelInstallCenter.remove() }
        case .failed:
            Button(L10n.llmModelRetry) { llmModelInstallCenter.startInstall() }
        case .notInstalled:
            if llmModelInstallCenter.consentGranted {
                Button(L10n.llmModelDownload) { llmModelInstallCenter.startInstall() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(L10n.llmModelConsentDownload) { llmModelInstallCenter.grantConsentAndInstall() }
                    .buttonStyle(.borderedProminent)
                Text(L10n.llmModelConsentHint(t2SizeText))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 状态副行文案（诚实呈现：相位/版本/更新可用/失败原因）。
    private var t2StatusText: String {
        switch llmModelInstallCenter.state {
        case .notInstalled:
            return L10n.llmModelStatusNotInstalled(t2SizeText)
        case .downloading:
            return L10n.asrModelDownloading
        case .verifying:
            return L10n.llmModelPhaseVerifying
        case .activating:
            return L10n.llmModelPhaseActivating
        case .installed:
            let installed = llmModelInstallCenter.installedVersion ?? "?"
            if llmModelInstallCenter.updateAvailable, let entry = llmModelInstallCenter.entry {
                return L10n.llmModelStatusUpdate(installed, entry.version)
            }
            return L10n.llmModelStatusInstalled(installed)
        case .failed(let kind):
            switch kind {
            case .verify: return L10n.llmModelFailedVerify
            case .needSpace: return L10n.llmModelFailedSpace
            case .network: return L10n.llmModelFailedNetwork
            case .other: return L10n.llmModelFailedOther
            }
        }
    }

    private var t2SizeText: String {
        let bytes = llmModelInstallCenter.entry?.bytes ?? llmModelInstallCenter.installedBytes
        return ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }

    /// ASR 阶段文案（2026-09-28 键族归并：activeSection 展示的就是 ASR 安装，
    /// 复用 asr.model.* 键——resourcePhase* 键族退役，阶段文案单一事实源）。
    private func phaseText(_ phase: ASRModelDownloadService.InstallPhase?) -> String {
        guard let phase else { return L10n.asrModelQueued }
        switch phase {
        case .downloading: return L10n.asrModelDownloading
        case .verifying: return L10n.asrModelPhaseVerifying
        case .unpacking: return L10n.asrModelPhaseUnpacking
        case .activating: return L10n.asrModelPhaseActivating
        case .pruning: return L10n.asrModelPhasePruning
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
