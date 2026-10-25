import SwiftUI

/// 启动门唯一可见页面：本地数据库未就绪前不挂载主界面。
/// 设计约束：三语 L10n、无硬编码颜色/字号、失败态可重试、VoiceOver 可读。
struct DatabaseInitializationView: View {
    @ObservedObject var model: DatabaseBootModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 20) {
                iconBadge
                VStack(spacing: 8) {
                    Text(model.failure == nil ? L10n.startupInitTitle : L10n.startupInitFailureTitle)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("STARTUP.initialization.title")
                    if model.failure == nil {
                        Text(L10n.startupInitSubtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                if model.failure == nil {
                    stageBlock
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
        case .assembling, .ready: return 2
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
        case .assembling: return "square.grid.2x2"
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
        case .assembling: return L10n.startupInitStageAssemble
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
