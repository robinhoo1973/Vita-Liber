import Foundation
import Domain

/// 写回 Apple 健康（业主 2026-09-17 定：本机确认的手输指标 → HealthKit）。
/// 与 `HealthReadingProvider` 分离——读契约的既有实现与测试替身不受写回影响；
/// 生产实现 `HealthKitReader` 同时遵循两者（AppContainer 以同一实例注入）。
///
/// 权限语义与读取侧不同：`authorizationStatus(for:)` **可以**观察分享（写）权限
/// （health-import-improve V1.8 §0）——「未授权/被拒绝」是如实可报的状态，
/// 不像读取权限那样不可观察。
public protocol HealthWritingProvider: Sendable {
    /// 申请分享（写）授权；系统流程未完成时抛 `HealthWriteError.requestIncomplete`
    /// （完成 ≠ 获准，由 `writeAuthorizationStatus()` 如实观察）。
    func requestWriteAuthorization() async throws
    /// 写回类型的分享授权状态（可观察事实）。
    func writeAuthorizationStatus() async -> HealthWriteAuthStatus
    /// 写回样本；单位不符/类型不可写的条目**跳过**，返回实际写入条数。
    @discardableResult
    func writeBack(_ samples: [HealthSampleDraft]) async throws -> Int
}

/// 写回授权状态（三态如实呈现：未决定 ≠ 拒绝，与读取侧 V3.78 同纪律）。
public enum HealthWriteAuthStatus: Sendable, Equatable {
    case granted        // 全部写回类型已获分享授权
    case denied         // 至少一个类型被拒（可在健康 App 隐私设置重新开启）
    case notDetermined  // 尚未请求 / 授权单未完成
}

public enum HealthWriteError: Error, Sendable, Equatable {
    case unavailable          // 设备不提供 HealthKit（iPad 等）
    case requestIncomplete    // 系统授权流程尚未完成
    case failed               // 其余写入失败（授权被拒/系统错误）
}
