import SwiftUI
import Domain
import Perception

/// 启动门唯一可见页面：本地数据库未就绪前不挂载主界面。
/// 设计约束：三语 L10n、无硬编码颜色/字号、失败态可重试、VoiceOver 可读。
struct DatabaseInitializationView: View {
    @ObservedObject var model: DatabaseBootModel

    var body: some View {
        WithPerceptionTracking {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
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
            Spacer(minLength: 24)
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

    @ViewBuilder
    private var catalogCard: some View {
        if let catalog = model.catalog {
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.startupCatalogTitle, systemImage: "books.vertical")
                    .font(.headline)
                Text(catalogStatus(catalog))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = catalog.updateProgress {
                    if case .downloading(let received, let total) = progress {
                        ProgressView(value: total > 0 ? min(1, Double(received) / Double(total)) : 0)
                    } else {
                        ProgressView()
                    }
                    Text(catalogPhaseText(progress))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let completed = catalog.updateCompletedDataVersion {
                    Label(L10n.resourceCatalogUpdateCompletedFmt(String(completed.prefix(8))),
                          systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                if catalog.updateError != nil {
                    Text(L10n.resourceCatalogUpdateFailed)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 10) {
                    if catalog.isUpdating {
                        Button(L10n.commonCancel) { catalog.cancelUpdate() }
                            .buttonStyle(.bordered)
                    } else if case .updateAvailable = catalog.remoteState {
                        Button(L10n.resourceCatalogUpdate) { model.installCatalog() }
                            .buttonStyle(.bordered)
                    } else {
                        Button(L10n.resourceCatalogCheck) { model.checkCatalog() }
                            .buttonStyle(.bordered)
                            .disabled(catalog.remoteState == .checking)
                    }
                    Button(L10n.startupCatalogContinue) { model.continueToApp() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(minHeight: 44)
                Text(L10n.resourceCatalogPrivacy)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: VLCornerRadius.compact))
            .accessibilityIdentifier("STARTUP.catalog")
        }
    }

    private func catalogStatus(_ catalog: MedicalCatalogState) -> String {
        switch catalog.remoteState {
        case .idle:
            return catalog.isAvailable ? L10n.resourceCatalogUpToDate : L10n.resourceCatalogNotAvailable
        case .checking: return L10n.resourceCatalogChecking
        case .upToDate: return L10n.resourceCatalogUpToDate
        case .updateAvailable(let candidate): return L10n.resourceCatalogUpdateAvailableFmt(candidate.catalogVersion)
        case .noInstallableAvailable: return L10n.resourceCatalogNoInstallable
        case .unavailable: return L10n.resourceCatalogUnavailable
        case .rateLimited: return L10n.resourceCatalogRateLimited
        case .verificationFailed: return L10n.resourceCatalogVerificationFailed
        case .networkUnavailable: return L10n.resourceCatalogNetworkUnavailable
        }
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

    private var iconBadge: some View {
        Image(systemName: model.failure == nil ? "heart.text.square.fill" : "exclamationmark.triangle.fill")
            .font(VLFont.homeActionIcon)
            .foregroundStyle(model.failure == nil ? Color.accentColor : Color.orange)
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
            // 触控目标 ≥44pt（ui-ux §3.3）
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
