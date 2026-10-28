#if DEBUG
import Foundation

/// 样张图库（2026-10-29）：**仅 DEBUG 编译**的 UI 演示层。
///
/// 边界纪律：样张不属于任何产品功能域——不接真实 store、不写盘、不联网、
/// 不读 EntitlementStore（红线模块纪律同理）；只在模拟器以
/// `-uitest-samples` 启动参数直达（宿主注入点见 VitaLiberApp.body）。
/// 演示状态一律留本层，禁止塞进生产 AppState/AppRouter。

/// 通用屏幕状态（样张层自用；故意不引 Perception——纯值类型 + @State 足矣）。
enum ScreenState<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    case empty
    case failed(String)

    var isLoading: Bool { if case .loading = self { return true }; return false }
    var value: Value? { if case .loaded(let value) = self { return value }; return nil }
    var failure: String? { if case .failed(let message) = self { return message }; return nil }
}

/// 追踪阶段（Camera/Dashboard 样张共用状态机演示）。
enum TrackingStage: String, CaseIterable, Sendable {
    case idle, preparing, active, paused, completed

    var title: String {
        switch self {
        case .idle: return "Not Started"
        case .preparing: return "Preparing"
        case .active: return "Tracking"
        case .paused: return "Paused"
        case .completed: return "Completed"
        }
    }
}

/// 被追踪模型（穿戴设备/训练对象的最小事实集）。
struct TrackedModel: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var isConnected: Bool
    /// 0...1；演示值，不接真实电量。
    var batteryLevel: Double

    static let sample = TrackedModel(
        id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!,
        name: "Aurora Band",
        isConnected: true,
        batteryLevel: 0.72)
}

/// 训练会话（Dashboard 样张事实源；Camera 样张用 stage 演示拍摄状态同构）。
struct WorkoutSession: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var trackedModel: TrackedModel
    var stage: TrackingStage
    var startedAt: Date
    var duration: TimeInterval
    var calories: Double
    var averageHeartRate: Int

    var isFinished: Bool { stage == .completed }
    /// 进行中 = 已离开未开始态且未完成（Dashboard 卡片「Resume」判据）。
    var isInProgress: Bool { stage == .active || stage == .paused || stage == .preparing }

    static func sample(stage: TrackingStage = .active) -> WorkoutSession {
        WorkoutSession(
            id: UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!,
            title: "Morning Run",
            trackedModel: .sample,
            stage: stage,
            startedAt: Date(timeIntervalSince1970: 1_760_000_000),
            duration: 32 * 60,
            calories: 287,
            averageHeartRate: 132)
    }
}

/// 异步仓库契约（样张注入点）：接口刻意窄，预览/测试可整替。
/// actor 实现保证 Swift 6 严格并发下无数据竞争（演示层不持锁）。
protocol AsyncWorkoutRepository: Sendable {
    func fetchSessions() async throws -> [WorkoutSession]
    func fetchTrackedModel() async throws -> TrackedModel
    func save(_ session: WorkoutSession) async throws
}

/// 演示仓库：确定性延迟 + 内存态；不落盘、不联网、可注入失败态演示 ScreenState。
actor StubWorkoutRepository: AsyncWorkoutRepository {
    private var sessions: [WorkoutSession]
    private let model: TrackedModel
    /// 调试开关：为 true 时 fetch 抛错，供样张切换 failed 态。
    private let simulateFailure: Bool

    init(sessions: [WorkoutSession] = [.sample()],
         model: TrackedModel = .sample,
         simulateFailure: Bool = false) {
        self.sessions = sessions
        self.model = model
        self.simulateFailure = simulateFailure
    }

    private func simulateLatency() async throws {
        try await Task.sleep(nanoseconds: 350_000_000)
        if simulateFailure { throw SampleRepositoryError.offline }
    }

    func fetchSessions() async throws -> [WorkoutSession] {
        try await simulateLatency()
        return sessions
    }

    func fetchTrackedModel() async throws -> TrackedModel {
        try await simulateLatency()
        return model
    }

    func save(_ session: WorkoutSession) async throws {
        try await simulateLatency()
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
    }
}

enum SampleRepositoryError: LocalizedError {
    case offline
    var errorDescription: String? {
        "Simulated offline error (samples only)."
    }
}
#endif
