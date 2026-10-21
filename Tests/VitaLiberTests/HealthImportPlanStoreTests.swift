import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure

// binds: SU-M2-F16
/// 业主 2026-10-20：导入范围 + 初始完成态（v36）。
@MainActor
final class HealthImportPlanStoreTests: XCTestCase {
    private func makeStore() async throws -> (GRDBStore, HealthImportStore) {
        let (db, _) = try await GRDBStore.inMemoryWithOwner()
        return (db, HealthImportStore(writer: db.writer))
    }

    func testConnectAlwaysUsesPast365DaysAndStartsInitialMode() async throws {
        let (_, store) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC", depth: .fiveYears)
        XCTAssertEqual(binding.historyDepth, .oneYear, "导入窗口固定 365 天，忽略更大深度参数")
        let plan = try await store.plan()
        XCTAssertEqual(plan?.depth, .oneYear)
        XCTAssertNil(plan?.initialCompletedAt)
        let mode = try await store.importMode()
        XCTAssertTrue(mode.isInitial)
        XCTAssertEqual(Set(mode.remainingKinds), Set(HealthDataKind.allCases))
    }

    func testCompletionFlipsModeToIncremental() async throws {
        let (_, store) = try await makeStore()
        _ = try await store.connect(timeZoneID: "UTC", depth: .oneYear)
        for kind in HealthDataKind.allCases {
            try await store.markRecentComplete(kind: kind)
            try await store.markHistoryComplete(kind: kind, depth: .oneYear)
        }
        let completed = try await store.markInitialCompletedIfCovered()
        XCTAssertTrue(completed)
        let mode = try await store.importMode()
        XCTAssertEqual(mode, .incremental)
        let plan = try await store.plan()
        XCTAssertNotNil(plan?.initialCompletedAt)
    }

    func testExtendingDepthIsClampedTo365AndKeepsCompletion() async throws {
        let (db, store) = try await makeStore()
        _ = try await store.connect(timeZoneID: "UTC", depth: .oneYear)
        for kind in HealthDataKind.allCases {
            try await store.markRecentComplete(kind: kind)
            try await store.markHistoryComplete(kind: kind, depth: .oneYear)
        }
        _ = try await store.markInitialCompletedIfCovered()
        let before = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") ?? 0 }

        _ = try await store.setHistoryDepth(.fiveYears)
        let plan = try await store.plan()
        XCTAssertEqual(plan?.depth, .oneYear, "扩大深度被收敛到 365 天")
        XCTAssertNotNil(plan?.initialCompletedAt, "一年范围已完成，无需重新初始回填")
        let mode = try await store.importMode()
        XCTAssertFalse(mode.isInitial)
        let after = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") ?? 0 }
        XCTAssertEqual(before, after, "缩小/扩大范围都不删已导入行")
    }

    func testCyclePersistsStableKindsAndCompletion() async throws {
        let (_, store) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC", depth: .oneYear)
        try await store.beginCycle(binding: binding)
        try await store.markKindStable(binding: binding, kind: .sleep)
        try await store.markKindStable(binding: binding, kind: .sleep)
        var state = try await store.cycleState(binding: binding)
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.stableKinds, [.sleep])

        try await store.clearKindStable(binding: binding, kind: .sleep)
        state = try await store.cycleState(binding: binding)
        XCTAssertTrue(state.stableKinds.isEmpty, "observer 新数据必须清稳定标记")

        for kind in HealthDataKind.allCases {
            try await store.markKindStable(binding: binding, kind: kind)
        }
        try await store.completeCycle(binding: binding)
        state = try await store.cycleState(binding: binding)
        XCTAssertTrue(state.isComplete)
        XCTAssertEqual(state.stableKinds, Set(HealthDataKind.allCases))
        try await store.beginCycle(binding: binding)
        state = try await store.cycleState(binding: binding)
        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.stableKinds.isEmpty)
    }

    func testBlockedKindNeverCountsAsCompleteAndResetForcesRefetch() async throws {
        let (_, store) = try await makeStore()
        _ = try await store.connect(timeZoneID: "UTC", depth: .oneYear)
        for kind in HealthDataKind.allCases {
            try await store.markRecentComplete(kind: kind)
            try await store.markHistoryComplete(kind: kind, depth: .oneYear)
        }
        try await store.markBlocked(kind: .sleep, reason: "authorization denied")
        let blockedMode = try await store.importMode()
        XCTAssertTrue(blockedMode.isInitial)
        let blockedPlan = try await store.plan()
        XCTAssertTrue(blockedPlan?.remainingKinds(depth: .oneYear).contains(.sleep) ?? false)

        try await store.resetKind(.sleep)
        let plan = try await store.plan()
        XCTAssertFalse(plan?.completion(.sleep).blocked ?? true)
        XCTAssertNil(plan?.completion(.sleep).recentCompletedAt)
    }

    func testLegacyFiveYearBindingIsNormalizedTo365Days() async throws {
        let (_, store) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC", depth: .fiveYears)
        XCTAssertEqual(binding.historyDepth, .oneYear)
        XCTAssertEqual(store.scopes(for: binding).map(\.lane), [.recent],
                       "超过 365 天的历史道不再存在")
    }

    func testDiscardPendingRemovesOnlyInFlightPage() async throws {
        let (_, store) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC", depth: .oneYear)
        let recent = try XCTUnwrap(store.scopes(for: binding).first { $0.lane == .recent })
        _ = try await store.stage(binding: binding, kind: .heartRate, scope: recent,
            previousAnchor: nil,
            page: HealthChangeBatch(added: [], deleted: [], anchor: Data([1]), hasMore: false))
        try await store.discardPending(kind: .heartRate)
        let pending = try await store.pendingBatch(binding: binding, kind: .heartRate)
        XCTAssertNil(pending)
    }

    func testRecentPendingSurvivesPrepareRecentLane() async throws {
        let (_, store) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC", depth: .all)
        let recent = try XCTUnwrap(store.scopes(for: binding).first { $0.lane == .recent })
        _ = try await store.stage(binding: binding, kind: .heartRate, scope: recent,
            previousAnchor: nil,
            page: HealthChangeBatch(added: [], deleted: [], anchor: Data([1]), hasMore: false))
        try await store.prepareRecentLane(binding: binding, kind: .heartRate)
        let pending = try await store.pendingBatch(binding: binding, kind: .heartRate)
        XCTAssertEqual(pending?.lane, .recent)
        XCTAssertEqual(pending?.batch.anchor, Data([1]),
                       "v4 committed anchor 未到道末时，fetch/pending 已是首填进度，不得误删")
    }

    func testUncoveredKindKeepsInitialMode() async throws {
        let (_, store) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC", depth: .oneYear)
        for kind in HealthDataKind.allCases where kind != .steps {
            try await store.markRecentComplete(kind: kind)
            try await store.markHistoryComplete(kind: kind, depth: .oneYear)
        }
        _ = try await store.stage(binding: binding, kind: .steps,
            previousAnchor: nil,
            page: HealthChangeBatch(added: [], deleted: [], anchor: Data([9]), hasMore: false))
        let pendingMode = try await store.importMode()
        XCTAssertTrue(pendingMode.isInitial)
    }
}
