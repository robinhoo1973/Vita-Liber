import Foundation
import Domain

public protocol HealthReadingProvider: Sendable {
    func isAvailable() async -> Bool
    func requestAuthorization() async throws
    /// round2 H-N1：按分道（近 365 天 / 更早历史）谓词分页；`anchor` 为该道独立游标。
    func changes(for kind: HealthDataKind, scope: HealthFetchScope, anchor: Data?, limit: Int) async throws -> HealthChangeBatch
    func snapshot(for window: HealthImportWindow, calendar: Calendar) async throws -> HealthWindowSnapshot
}
