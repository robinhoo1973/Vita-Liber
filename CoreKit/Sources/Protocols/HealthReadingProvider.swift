import Foundation
import Domain

public protocol HealthReadingProvider: Sendable {
    func isAvailable() async -> Bool
    func requestAuthorization() async throws
    func changes(for kind: HealthDataKind, anchor: Data?, limit: Int) async throws -> HealthChangeBatch
    func snapshot(for window: HealthImportWindow, calendar: Calendar) async throws -> HealthWindowSnapshot
}
