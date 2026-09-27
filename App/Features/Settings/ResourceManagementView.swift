import SwiftUI
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

    private var resourcesSection: some View {
        Section(L10n.resourceCatalogTitle) {
            // 医疗数据目录（B2-1 只读本地状态；Check/Update 在 B2-3）
            HStack {
                Label(L10n.resourceCatalogRow, systemImage: "pills.fill")
                Spacer()
                if catalogState.isAvailable {
                    Text(L10n.resourceInstalled)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.resourceNotInstalled)
                        .font(.caption)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("SP-64.resource.catalog")

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

    private func byteText(_ received: Int64, _ total: Int64) -> String {
        L10n.resourceProgressBytes(received, total)
    }
}
