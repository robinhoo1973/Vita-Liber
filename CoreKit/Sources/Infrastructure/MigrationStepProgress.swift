import Foundation

/// 迁移步骤进度（2026-11-01 迁移安全网；三席两轮裁决）。
///
/// 运行在 `GRDBStore.migrateIncremental` 的数据库写线程内——回调必须
/// **非阻塞**：只做投递（`Task { @MainActor ... }`），不得等待 UI 或抛错。
/// 进度类型与 GRDB 解耦，Linux 可编译/测试；是否消费由 App 决定。
public struct MigrationStepProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case started
        case finished
    }

    /// 该步骤完成后的目标 `PRAGMA user_version`。
    public let version: Int
    /// 1-based 步序（pending 集合内）。
    public let index: Int
    /// pending 集合总步数。
    public let total: Int
    /// `SchemaMigrations.Step.name`（仅日志/诊断，不直接上屏）。
    public let name: String
    public let phase: Phase

    public init(version: Int, index: Int, total: Int, name: String, phase: Phase) {
        self.version = version
        self.index = index
        self.total = total
        self.name = name
        self.phase = phase
    }

    /// 已完成步数（started 时表示「正在做第 index 步」，完成数 = index-1）。
    public var completedSteps: Int {
        phase == .finished ? index : max(index - 1, 0)
    }
}

/// `@Sendable` 同步回调：迁移线程直接调用，调用方负责投递到主线程。
public typealias MigrationProgressHandler = @Sendable (MigrationStepProgress) -> Void
