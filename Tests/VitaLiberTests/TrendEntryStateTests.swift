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
        let (db, owner) = try await GRDBStore.inMemoryWithOwner()
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

    /// 业主 2026-09-16 第 1 项：「指标趋势页数据显示的起点应该是当前日期，而不是最近
    /// 的那条记录」。本用例是**锚点策略**的回归位——此前 App 层没有任何测试能区分
    /// 「锚今天」与「锚最新读数」（种子数据都在一小时前，两种策略结果相同）：
    /// 新版把种子的最新读数放到 90 天前，窗末仍必须是今天。
    func test_windowIsAnchoredToTodayNotTheNewestReading() async throws {
        let (db, owner) = try await GRDBStore.inMemoryWithOwner()
        let trends = TrendQueryStore(writer: db.writer)
        let stale = Date().addingTimeInterval(-90 * 86400)
        _ = try await trends.addSample(patientId: owner, metric: .glucose, value: 5.6, secondaryValue: nil,
                                       unit: "mmol/L", measuredAt: stale)
        let state = TrendEntryState(store: trends)

        // 断言「窗口覆盖了**发起请求的那一刻**」——这才是业主第 1 项的语义。
        // 必须在 `await` **之前**取时刻：`period(endingAt:)` 的 `end` 与传入锚点逐位
        // 相等（Domain 该函数注释明示），而 `loadDetail` 内部的锚点晚于此处；若在
        // `await` 之后再取 `Date()`，它必然晚于 `end`，而 `DateInterval.contains`
        // 是双端闭区间 → 判否（CI 35085355700 实证：本行曾写成 `contains(Date())`，
        // 差的是微秒，报 XCTAssertTrue failed）。
        let requestedAt = Date()
        await state.loadDetail(patientId: owner, metricKey: "glucose", window: .week)
        let identity = try XCTUnwrap(state.detailIdentity)
        // 窗末 = 今天（允许跨用例的秒级误差），而不是最新读数所在日
        XCTAssertEqual(identity.range.end.timeIntervalSinceNow, 0, accuracy: 5)
        XCTAssertTrue(identity.range.contains(requestedAt))
        XCTAssertFalse(identity.range.contains(stale), "90 天前的读数不应落在 7 天窗内")
        // 最新读数仍如实告知（空态出口的数据源）
        XCTAssertEqual(try XCTUnwrap(state.latestAnyDate).timeIntervalSince(stale), 0, accuracy: 0.001)
        XCTAssertNil(state.detailSeries?.points.first, "窗内无读数 → 空态（图表不画）")
    }

    func test_sleepMetricLoadsIntegratedSeriesFromAllStageKeys() async throws {
        let seed = try await makeSeed()
        let state = TrendEntryState(store: seed.trends)
        let night = Date().addingTimeInterval(-12 * 3600)
        _ = try await seed.trends.addDeviceSamples(patientId: seed.owner, rows: [
            DeviceMetricRow(metricKey: "sleep_total", value: 7.5, unit: "h", measuredAt: night),
            DeviceMetricRow(metricKey: "sleep_deep", value: 1.2, unit: "h", measuredAt: night),
            DeviceMetricRow(metricKey: "sleep_core", value: 4.0, unit: "h", measuredAt: night),
            DeviceMetricRow(metricKey: "sleep_awake", value: 0.5, unit: "h", measuredAt: night),
        ])
        await state.loadDetail(patientId: seed.owner, metricKey: "sleep_deep", window: .week)
        let sleep = try XCTUnwrap(state.sleepSeries, "睡眠族载入整合槽（不是单键点族槽）")
        XCTAssertEqual(state.detailSeries, nil, "两槽互斥")
        XCTAssertEqual(sleep.nights.count, 1)
        XCTAssertEqual(sleep.nights[0].asleepHours, 7.5)
        XCTAssertEqual(sleep.nights[0].slices.map(\.stage), [.deep, .core, .awake])
        XCTAssertEqual(sleep.identity, state.detailIdentity)
        // 宫格折叠：睡眠六键只出一块瓦片（sleep_total 恒胜）
        await state.loadLatest(patientId: seed.owner)
        let sleepTiles = state.latestMetrics.filter { MetricType(rawValue: $0.metricKey)?.isSleep == true }
        XCTAssertEqual(sleepTiles.count, 1)
        XCTAssertEqual(sleepTiles.first?.metricKey, "sleep_total")
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
