import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
@testable import VitaLiber

// binds: SU-M15-TREND
/// round2 H2/H4（子项目 C7）：趟趋势详情请求携带查询身份（patientId, metric, origin, range），
/// 状态槽只接受 `series.identity == detailIdentity` 的结果——并发切指标/切窗口时晚到的旧身份结果绝不落槽；
/// 时间窗与来源过滤进入身份；写后刷新沿用同一身份（含原范围），不重盖标记。
@MainActor
final class TrendEntryStateTests: XCTestCase {
    private struct Seed {
        let db: GRDBStore
        let trends: TrendQueryStore
        let owner: UUID
    }

    private func makeSeed() async throws -> Seed {
        let db = try GRDBStore.inMemory()
        let owner = UUID()
        try await db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, 'Owner', 'self', 0, 0)
                """, arguments: [owner.uuidString])
            try db.execute(sql: "INSERT INTO local_owner (id, display_name, self_patient_id, created_at) VALUES (?, 'Owner', ?, 0)",
                           arguments: [UUID().uuidString, owner.uuidString])
        }
        let trends = TrendQueryStore(writer: db.writer)
        // A 名下 heartRate 与 glucose 各一行（最近，落在任何时间窗内）
        let recent = Date().addingTimeInterval(-3600)
        _ = try await trends.addSample(patientId: owner, metric: .heartRate, value: 66, secondaryValue: nil,
                                       unit: "bpm", measuredAt: recent)
        _ = try await trends.addSample(patientId: owner, metric: .glucose, value: 5.6, secondaryValue: nil,
                                       unit: "mmol/L", measuredAt: recent)
        return Seed(db: db, trends: trends, owner: owner)
    }

    func test_detailSeriesAlwaysMatchesRequestedIdentity() async throws {
        let seed = try await makeSeed()
        let state = TrendEntryState(store: seed.trends)
        // 旧请求（heartRate/month）先入队并在首个 await 处挂起（@MainActor 上下文内的非结构化
        // Task 直接排入主执行器，Task.yield 让其跑到挂起点——顺序确定，不依赖全局执行器跳转时序）；
        // 随后新请求（glucose/week/manual）覆盖身份并完成；旧结果晚到必须被身份守卫丢弃。
        let stale = Task { await state.loadDetail(patientId: seed.owner, metricKey: "heartRate", window: .month, origin: nil) }
        await Task.yield()
        await state.loadDetail(patientId: seed.owner, metricKey: "glucose", window: .week, origin: .manual)
        await stale.value
        XCTAssertEqual(state.detailIdentity?.metric, .glucose)
        XCTAssertEqual(state.detailIdentity?.origin, .manual)
        XCTAssertEqual(state.detailIdentity?.patientId, seed.owner)
        // 旧请求（heartRate/month）结果绝不落槽：槽为空，或其身份与当前身份完全一致
        XCTAssertTrue(state.detailSeries == nil || state.detailSeries?.identity == state.detailIdentity)
        if let series = state.detailSeries {
            XCTAssertEqual(series.metricType, .glucose)
            XCTAssertEqual(Set(series.points.map(\.origin)), [.manual])
        }
        XCTAssertFalse(state.detailLoading)
    }

    func test_windowEntersIdentityRangeAsCalendarDays() async throws {
        let seed = try await makeSeed()
        let state = TrendEntryState(store: seed.trends)
        await state.loadDetail(patientId: seed.owner, metricKey: "heartRate", window: .week, origin: nil)
        let identity = try XCTUnwrap(state.detailIdentity)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: identity.range.start, to: identity.range.end).day, 7)
        XCTAssertEqual(state.detailSeries?.identity, identity)
        XCTAssertEqual(state.detailSeries?.points.count, 1)
        XCTAssertFalse(state.detailFailed)
    }

    func test_unknownMetricKeyClearsIdentityAndSeries() async throws {
        let seed = try await makeSeed()
        let state = TrendEntryState(store: seed.trends)
        await state.loadDetail(patientId: seed.owner, metricKey: "heartRate")
        XCTAssertNotNil(state.detailSeries)
        await state.loadDetail(patientId: seed.owner, metricKey: "not_a_metric")
        XCTAssertNil(state.detailIdentity, "未知指标键不得用真实指标顶替，也不得残留旧身份")
        XCTAssertNil(state.detailSeries)
    }

    func test_refreshDetailIfCurrentKeepsIdentityAndIgnoresOtherMetric() async throws {
        let seed = try await makeSeed()
        let state = TrendEntryState(store: seed.trends)
        await state.loadDetail(patientId: seed.owner, metricKey: "heartRate", window: .quarter, origin: nil)
        let identity = try XCTUnwrap(state.detailIdentity)
        // 其他指标的写后刷新不触碰当前槽
        await state.refreshDetailIfCurrent(patientId: seed.owner, metricKey: "glucose")
        XCTAssertEqual(state.detailIdentity, identity)
        XCTAssertEqual(state.detailSeries?.metricType, .heartRate)
        // 同身份刷新：新增一行后点数增长，身份（含原范围）保持不变
        _ = try await seed.trends.addSample(patientId: seed.owner, metric: .heartRate, value: 72, secondaryValue: nil,
                                            unit: "bpm", measuredAt: Date().addingTimeInterval(-7200))
        await state.refreshDetailIfCurrent(patientId: seed.owner, metricKey: "heartRate")
        XCTAssertEqual(state.detailIdentity, identity)
        XCTAssertEqual(state.detailSeries?.identity, identity)
        XCTAssertEqual(state.detailSeries?.points.count, 2)
    }
}
