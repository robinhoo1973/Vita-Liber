#if DEBUG
import SwiftUI
import Domain

/// 样张：训练仪表盘（仅 DEBUG；2026-10-29 样张图库批）。
///
/// 演示要点：AsyncWorkoutRepository 异步装配（ScreenState 四态：loading /
/// loaded / empty / failed）、进行中会话卡（Resume）、周活动柱状图（纯 SwiftUI
/// Capsule，不引 Charts——样张层不扩依赖面）、追踪设备状态（电量/连接）、
/// 会话列表（TrackingStage 胶囊）与深链按钮组（value 式 NavigationLink）。
/// 平台纪律：不硬编码字号/颜色（token 出口：VLCornerRadius / PillBadge /
/// Color(asset)），触控目标 ≥44pt。
struct DashboardSampleView: View {
    /// 注入点：预览可整替（默认演示仓库）。
    var repository: any AsyncWorkoutRepository = StubWorkoutRepository()

    @State private var sessionsState: ScreenState<[WorkoutSession]> = .loading
    @State private var trackedModel: TrackedModel?
    @State private var simulateFailure = false

    private let weekActivity: [Double] = [0.35, 0.62, 0.2, 0.8, 0.55, 0.95, 0.45]
    private let weekLabels = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                content
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    simulateFailure.toggle()
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier("sample.dashboard.reload")
                .accessibilityLabel(simulateFailure ? "Reload with simulated failure" : "Reload")
            }
        }
        .task { await load() }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Good morning")
                .font(.subheadline)
                .foregroundStyle(Color("text-secondary", bundle: .main))
            Text("Today's Training")
                .font(.title2.weight(.bold))
            if let trackedModel {
                HStack(spacing: 6) {
                    Circle()
                        .fill(trackedModel.isConnected
                              ? Color("semantic-success", bundle: .main)
                              : Color("text-secondary", bundle: .main))
                        .frame(width: 8, height: 8)
                    Text(trackedModel.name)
                        .font(.caption)
                        .foregroundStyle(Color("text-secondary", bundle: .main))
                    Text("· \(Int(trackedModel.batteryLevel * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color("text-secondary", bundle: .main))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 主体四态

    @ViewBuilder
    private var content: some View {
        switch sessionsState {
        case .loading:
            loadingCard
        case .failed(let message):
            failedCard(message)
        case .empty:
            emptyCard
        case .loaded(let sessions):
            loadedContent(sessions)
        }
    }

    private var loadingCard: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading sessions…")
                .font(.footnote)
                .foregroundStyle(Color("text-secondary", bundle: .main))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .glassCard()
    }

    private func failedCard(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(VLFont.disclosureIcon)
                .foregroundStyle(Color("semantic-warning", bundle: .main))
            Text(message)
                .font(.footnote)
                .foregroundStyle(Color("text-secondary", bundle: .main))
                .multilineTextAlignment(.center)
            Button("Retry") {
                simulateFailure = false
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("sample.dashboard.retry")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .glassCard()
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.run.circle")
                .font(VLFont.disclosureIcon)
                .foregroundStyle(Color("text-secondary", bundle: .main))
            Text("No sessions yet")
                .font(.subheadline.weight(.medium))
            Text("Start your first session from the Camera sample.")
                .font(.footnote)
                .foregroundStyle(Color("text-secondary", bundle: .main))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .glassCard()
    }

    private func loadedContent(_ sessions: [WorkoutSession]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let current = sessions.first(where: \.isInProgress) {
                resumeCard(current)
            }
            weekChart
            sessionList(sessions)
            quickActions
        }
    }

    // MARK: - 子卡

    private func resumeCard(_ session: WorkoutSession) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                PillBadge(text: session.stage.title, style: .brand, size: .small)
                Text(session.title)
                    .font(.headline)
                Text("\(Int(session.duration / 60)) min · \(Int(session.calories)) kcal · \(session.averageHeartRate) bpm")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color("text-secondary", bundle: .main))
            }
            Spacer()
            NavigationLink(value: SamplesRoute.camera) {
                Text("Resume")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color("brand-primary", bundle: .main), in: Capsule())
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityIdentifier("sample.dashboard.resume")
        }
        .padding(16)
        .glassCard()
    }

    private var weekChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This Week")
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(weekActivity.enumerated()), id: \.offset) { index, value in
                    VStack(spacing: 6) {
                        Capsule()
                            .fill(value >= 0.8
                                  ? Color("brand-primary", bundle: .main)
                                  : Color("brand-primary", bundle: .main).opacity(0.35))
                            .frame(width: 22, height: max(8, 96 * value))
                        Text(weekLabels[index])
                            .font(.caption2)
                            .foregroundStyle(Color("text-secondary", bundle: .main))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .glassCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sample.dashboard.weekChart")
    }

    private func sessionList(_ sessions: [WorkoutSession]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Sessions")
                .font(.subheadline.weight(.semibold))
            ForEach(sessions) { session in
                HStack(spacing: 12) {
                    Image(systemName: session.isFinished ? "checkmark.circle.fill" : "figure.run")
                        .font(.title3)
                        .foregroundStyle(session.isFinished
                                         ? Color("semantic-success", bundle: .main)
                                         : Color("brand-primary", bundle: .main))
                        .frame(width: 36, height: 36)
                        .background(Color("brand-primary", bundle: .main).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .font(.subheadline.weight(.medium))
                        Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(Color("text-secondary", bundle: .main))
                    }
                    Spacer()
                    PillBadge(text: session.stage.title,
                              style: session.isFinished ? .neutral : .brand,
                              size: .small)
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: VLCornerRadius.compact, style: .continuous))
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            quickAction(icon: "camera.viewfinder", title: "Camera", route: .camera,
                        identifier: "sample.dashboard.deeplink.camera")
            quickAction(icon: "gearshape", title: "Settings", route: .settings,
                        identifier: "sample.dashboard.deeplink.settings")
        }
    }

    private func quickAction(icon: String, title: String, route: SamplesRoute,
                             identifier: String) -> some View {
        NavigationLink(value: route) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                Text(title)
                    .font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .glassCard(cornerRadius: VLCornerRadius.compact)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityIdentifier(identifier)
    }

    // MARK: - 装配

    private func load() async {
        sessionsState = .loading
        do {
            let repo: any AsyncWorkoutRepository = simulateFailure
                ? StubWorkoutRepository(simulateFailure: true)
                : repository
            let model = try await repo.fetchTrackedModel()
            let sessions = try await repo.fetchSessions()
            trackedModel = model
            sessionsState = sessions.isEmpty ? .empty : .loaded(sessions)
        } catch {
            sessionsState = .failed(error.localizedDescription)
        }
    }
}

#Preview("Dashboard") {
    NavigationStack {
        DashboardSampleView()
            .navigationDestination(for: SamplesRoute.self) { route in
                route.destination
            }
    }
}
#endif
