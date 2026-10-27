import SwiftUI
import UIKit
import Domain
import Perception

/// 启动门唯一可见页面：本地数据库未就绪前不挂载主界面。
/// 设计约束：三语 L10n、无硬编码颜色/字号、失败态可重试、VoiceOver 可读。
/// 医疗目录卡（2026-10-27 方案 B）：单主按钮 + 单次动作，完成/无候选自动进入；
/// 两次显式点击语义不变（检查只取元数据，下载是第二次显式动作）。
struct DatabaseInitializationView: View {
    @ObservedObject var model: DatabaseBootModel

    var body: some View {
        WithPerceptionTracking {
            content
        }
    }

    private var content: some View {
        // 大字号下可滚动（ui-ux §5.12.4「大字号可滚动」）；本页在 session 之前，
        // 无法读取关怀模式，触控目标一律从宽 ≥64pt。
        ScrollView {
            VStack(spacing: 20) {
                iconBadge
                VStack(spacing: 8) {
                    Text(titleText)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("STARTUP.initialization.title")
                    if model.failure == nil {
                        Text(model.awaitingCatalogChoice ? L10n.startupCatalogBody : L10n.startupInitSubtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                if model.failure == nil {
                    if model.awaitingCatalogChoice {
                        catalogCard
                    } else {
                        stageBlock
                    }
                }
                privacyRow
                if let failure = model.failure {
                    failureCard(failure)
                        .transition(.opacity)
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .glassCard()
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tintedCanvas()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("STARTUP.initialization")
    }

    private var titleText: String {
        if model.failure != nil { return L10n.startupInitFailureTitle }
        if model.awaitingCatalogChoice { return L10n.startupInitReadyTitle }
        return L10n.startupInitTitle
    }

    // MARK: - 医疗目录卡（方案 B：descriptor 驱动）

    @ViewBuilder
    private var catalogCard: some View {
        if let catalog = model.catalog {
            let input = MedicalCatalogPromptInput(catalog: catalog)
            let descriptor = MedicalCatalogPromptPresentation.descriptor(input)
            let candidate = candidateOf(catalog)
            let size = candidate.map { MedicalCatalogPromptCopy.sizeText($0.packageSize) }
            let statusText = MedicalCatalogPromptCopy.statusText(descriptor.status, candidateSize: size)

            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.startupCatalogTitle, systemImage: "books.vertical")
                    .font(.headline)
                if case .completed = descriptor.status {
                    Label(statusText, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color("semantic-success", bundle: .main))
                } else {
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .candidate = descriptor.status {
                    Text(L10n.startupCatalogSizeHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if case .phase(let progress) = descriptor.status {
                    catalogProgress(progress)
                }
                if case .phase(.activating) = descriptor.status {
                    Text(L10n.startupCatalogActivating)
                        .font(.footnote)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                }
                catalogActions(descriptor, sizeText: size)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: VLCornerRadius.compact))
            // 容器标识必须配 .contain，否则标识会压到子按钮上（L0 第 17 节）。
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("STARTUP.catalog")
            .onChangeCompat(of: catalogPhaseKey(catalog.updateProgress)) { _, _ in
                if let progress = catalog.updateProgress {
                    UIAccessibility.post(notification: .announcement,
                                         argument: MedicalCatalogPromptCopy.phaseText(progress))
                }
            }
            .onChangeCompat(of: catalog.updateCompletedDataVersion) { _, _ in
                announceCompleted(catalog)
                model.scheduleAutoEnterIfNeeded()
            }
            .onChangeCompat(of: catalog.remoteState) { _, state in
                switch state {
                case .upToDate, .noInstallableAvailable:
                    UIAccessibility.post(notification: .announcement,
                                         argument: MedicalCatalogPromptCopy.remoteText(state))
                    model.scheduleAutoEnterIfNeeded()
                case .unavailable, .networkUnavailable, .verificationFailed, .rateLimited:
                    UIAccessibility.post(notification: .announcement,
                                         argument: MedicalCatalogPromptCopy.remoteText(state))
                default:
                    break
                }
            }
            .onChangeCompat(of: catalog.updateError) { _, error in
                if let error {
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: MedicalCatalogPromptCopy.errorText(
                            error, hasLocal: catalog.localVersion != nil))
                }
            }
        }
    }

    /// 每个状态最多一个主按钮 + 一个低强调次动作；busy/none 的主按钮禁用。
    private func catalogActions(_ descriptor: MedicalCatalogPromptDescriptor,
                                sizeText: String?) -> some View {
        VStack(spacing: 12) {
            Button {
                perform(descriptor.primary)
            } label: {
                HStack(spacing: 8) {
                    if descriptor.primary == .busy {
                        ProgressView().controlSize(.small)
                    }
                    Text(MedicalCatalogPromptCopy.primaryTitle(descriptor, candidateSize: sizeText))
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(descriptor.primary == .busy || descriptor.primary == .none)
            .contentShape(Rectangle())
            .accessibilityIdentifier("STARTUP.catalog.primary")
            .accessibilityHint(primaryHint(descriptor.primary))

            if let secondary = descriptor.secondary {
                Button {
                    perform(secondary)
                } label: {
                    Text(MedicalCatalogPromptCopy.secondaryTitle(secondary))
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityIdentifier("STARTUP.catalog.continue")
                .accessibilityHint(secondaryHint(secondary))
            }
        }
    }

    private func perform(_ action: MedicalCatalogPromptAction) {
        switch action {
        case .check, .recheck: model.checkCatalog()
        case .install, .retryInstall: model.installCatalog()
        case .enter, .enterKeepingUpdate: model.enterKeepingUpdate()
        case .continueWithout, .cancelCheckAndContinue, .cancelUpdateAndContinue:
            model.continueToApp()
        case .busy, .none: break
        }
    }

    private func primaryHint(_ action: MedicalCatalogPromptAction) -> String {
        switch action {
        case .check, .recheck: return L10n.updateCenterCheckAllHint
        case .install, .retryInstall: return L10n.resourceCatalogUpdateHint
        default: return ""
        }
    }

    private func secondaryHint(_ action: MedicalCatalogPromptAction) -> String {
        switch action {
        case .cancelCheckAndContinue: return L10n.resourceCatalogCancelCheckHint
        case .cancelUpdateAndContinue: return L10n.resourceCatalogCancelHint
        default: return ""
        }
    }

    private func announceCompleted(_ catalog: MedicalCatalogState) {
        let version = catalog.updateCompletedCatalogVersion
        let text = version.map { L10n.startupCatalogCompletedFmt($0) }
            ?? L10n.startupCatalogCompleted
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func candidateOf(_ catalog: MedicalCatalogState) -> MedicalCatalogUpdateCandidate? {
        if case .updateAvailable(let candidate) = catalog.remoteState { return candidate }
        return nil
    }

    @ViewBuilder
    private func catalogProgress(_ progress: MedicalCatalogDownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .downloading(let received, let total) = progress {
                ProgressView(value: total > 0 ? min(1, Double(received) / Double(total)) : 0)
                    .accessibilityValue(percentText(received, total))
                    .accessibilityAddTraits(.updatesFrequently)
                Text(L10n.resourceProgressBytes(byteText(received), byteText(total)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(percentText(received, total))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(L10n.resourceCatalogDownloadingKeepOpen)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(L10n.startupCatalogBackgroundGrace)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("STARTUP.catalog.progress")
    }

    /// 稳定阶段键：只播报阶段切换，下载字节变化不触发播报。
    private func catalogPhaseKey(_ progress: MedicalCatalogDownloadProgress?) -> String {
        guard let progress else { return "idle" }
        switch progress {
        case .downloading: return "downloading"
        case .verifyingPackage: return "verifyingPackage"
        case .decrypting: return "decrypting"
        case .verifyingCatalog: return "verifyingCatalog"
        case .activating: return "activating"
        }
    }

    private func percentText(_ received: Int64, _ total: Int64) -> String {
        guard total > 0 else { return "" }
        return "\(min(100, received * 100 / total))%"
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - 数据库阶段/失败（原样）

    private var iconBadge: some View {
        Image(systemName: model.failure == nil ? "heart.text.square.fill" : "exclamationmark.triangle.fill")
            .font(VLFont.homeActionIcon)
            .foregroundStyle(model.failure == nil ? Color.accentColor : Color("semantic-warning", bundle: .main))
            .frame(width: 88, height: 88)
            .background(.thinMaterial, in: Circle())
            .accessibilityHidden(true)
    }

    private var stageBlock: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(L10n.startupInitProgressA11y)
            HStack(spacing: 8) {
                Image(systemName: stageSymbol)
                    .foregroundStyle(.secondary)
                Text(stageText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            stepDots
        }
    }

    /// 三步视觉锚点：历史目录 → 物理探测/迁移 → 界面装配。
    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index < completedSteps ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: index == stepIndex ? 22 : 8, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private var stepIndex: Int {
        switch model.phase {
        case .idle, .rebuildingHistory: return 0
        case .probing, .creating, .migrating, .verifying: return 1
        case .assembling, .catalogChoice, .ready: return 2
        }
    }

    private var completedSteps: Int {
        model.phase == .ready ? 3 : stepIndex
    }

    private var stageSymbol: String {
        switch model.phase {
        case .idle, .rebuildingHistory: return "externaldrive.badge.timemachine"
        case .probing: return "magnifyingglass"
        case .creating: return "plus.square.on.square"
        case .migrating: return "arrow.triangle.2.circlepath"
        case .verifying: return "checkmark.shield"
        case .assembling, .catalogChoice: return "square.grid.2x2"
        case .ready: return "checkmark.circle.fill"
        }
    }

    private var stageText: String {
        switch model.phase {
        case .idle, .rebuildingHistory: return L10n.startupInitStageHistory
        case .probing: return L10n.startupInitStageProbe
        case .creating: return L10n.startupInitStageCreate
        case .migrating(let from, let to): return L10n.startupInitStageMigrate(from, to)
        case .verifying: return L10n.startupInitStageVerify
        case .assembling, .catalogChoice: return L10n.startupInitStageAssemble
        case .ready: return L10n.startupInitStageAssemble
        }
    }

    private var privacyRow: some View {
        Label(L10n.startupInitPrivacy, systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private func failureCard(_ failure: DatabaseBootFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(failureBody(failure))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await model.retry() }
            } label: {
                Text(L10n.startupInitRetry)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .accessibilityIdentifier("STARTUP.initialization.retry")
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: VLCornerRadius.compact))
    }

    private func failureBody(_ failure: DatabaseBootFailure) -> String {
        switch failure {
        case .missingWithOriginals:
            return L10n.startupInitFailureMissingOriginals
        case .corrupt:
            return L10n.startupInitFailureCorrupt
        case .tooNew:
            return L10n.startupInitFailureTooNew
        case .migrationIncomplete(let found, let expected):
            return L10n.startupInitFailureMigration(found, expected)
        case .openFailed, .unexpected:
            return L10n.startupInitFailureGeneric
        }
    }
}
