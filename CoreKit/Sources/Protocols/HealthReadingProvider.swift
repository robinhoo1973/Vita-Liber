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
}
