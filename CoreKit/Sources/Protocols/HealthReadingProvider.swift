import Foundation
import Domain

public protocol HealthReadingProvider: Sendable {
    func isAvailable() async -> Bool
    func requestAuthorization() async throws
    /// round2 H-N1：按分道（近 365 天 / 更早历史）谓词分页；`anchor` 为该道独立游标。
    func changes(for kind: HealthDataKind, scope: HealthFetchScope, anchor: Data?, limit: Int) async throws -> HealthChangeBatch
    func snapshot(for window: HealthImportWindow, calendar: Calendar) async throws -> HealthWindowSnapshot
    /// 特征型（血型 / 出生日期 / 生理性别）——**只读**，用户未填即如实为 nil。
    /// 业主 2026-09-17 定：导入走**档案候选**（D → 用户确认），不进趋势管道、不覆盖已有值。
    /// 平台边界：特征型不可写；医疗急救卡 / SOS 联系人无公开 API（只能引导用户手填，FR15.2）。
    func characteristics() async throws -> HealthCharacteristics
    /// 仅申请特征型读取授权——首启注册预填的**最小请求**（不把六类样本授权捆绑进来，WWDC20 纪律：
    /// 在真正需要的时机请求、只请求所需类型）。完成 ≠ 获准（同 `requestAuthorization` 语义）。
    func requestCharacteristicAuthorization() async throws
}

public extension HealthReadingProvider {
    /// 默认实现 = 完整读取授权请求（既有测试替身免改；生产 `HealthKitReader`
    /// 覆写为特征型最小请求）。
    func requestCharacteristicAuthorization() async throws {
        try await requestAuthorization()
    }

    /// 默认实现 = 无特征数据（既有测试替身免改——注册预填/候选读取在此形态下
    /// 如实无候选；生产 `HealthKitReader` 覆写为真实读取）。
    func characteristics() async throws -> HealthCharacteristics {
        HealthCharacteristics()
    }
}
