import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols

// binds: SU-M2-F16
@MainActor
final class HealthKitSyncServiceTests: XCTestCase {
    private func makeStore() async throws -> (GRDBStore, HealthImportStore, HealthImportStore.Binding) {
        let (db, _) = try await GRDBStore.inMemoryWithOwner()
        let imports = HealthImportStore(writer: db.writer)
        let binding = try await imports.connect(timeZoneID: "UTC")
        return (db, imports, binding)
    }

    private func service(_ db: GRDBStore, imports: HealthImportStore,
                         provider: HealthSyncFixtureProvider) -> HealthKitSyncService {
        HealthKitSyncService(provider: provider, imports: imports,
            guidelines: GuidelineStore(writer: db.writer), scheduler: InMemoryReminderScheduler())
    }

    private func discreteFixture(days: Int) -> (samples: [HealthSampleReference], snapshots: [HealthWindowSnapshot]) {
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let samples = (0..<days).map { day in
            let at = start.addingTimeInterval(Double(day) * 86400 + 60)
            return HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch", start: at, end: at)
        }
        let snapshots = samples.enumerated().map { day, sample in
            let lower = start.addingTimeInterval(Double(day) * 86400)
            let window = HealthImportWindow(kind: .bloodOxygen, start: lower, end: lower.addingTimeInterval(86400))
            let row = DeviceMetricRow(metricKey: "blood_oxygen", value: 98, unit: "%", measuredAt: sample.end,
                sourceRef: HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: sample.id, ordinal: nil))
            return HealthWindowSnapshot(window: window, samples: [sample], rows: [row])
        }
        return (samples, snapshots)
    }

    func test_partialSnapshotFailureKeepsCheckpointAndReplaysAfterRestart() async throws {
        let (db, imports, binding) = try await makeStore()
        let fixture = discreteFixture(days: 2)
        let provider = HealthSyncFixtureProvider(kind: .bloodOxygen,
            pages: [HealthChangeBatch(added: fixture.samples, deleted: [], anchor: Data([1]), hasMore: false)],
            snapshots: fixture.snapshots)
        await provider.failSnapshots([fixture.snapshots[1].window])
        let first = try await service(db, imports: imports, provider: provider).performSync(quietStart: "22:00", quietEnd: "07:00")
        let interimAnchor = try await imports.anchor(binding: binding, kind: .bloodOxygen)
        let interimRows = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(first.failedTypes, [.bloodOxygen])
        XCTAssertTrue(first.hasMore)
        XCTAssertNil(interimAnchor)
        XCTAssertEqual(interimRows, 1, "A failed window does not block unrelated completed projections")

        await provider.failSnapshots([])
        let restartedImports = HealthImportStore(writer: db.writer)
        let second = try await service(db, imports: restartedImports, provider: provider)
            .performSync(quietStart: "22:00", quietEnd: "07:00")
        let finalAnchor = try await restartedImports.anchor(binding: binding, kind: .bloodOxygen)
        let finalRows = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        let pending = try await restartedImports.pendingBatch(binding: binding, kind: .bloodOxygen)
        let requests = await provider.requests.filter { $0.kind == .bloodOxygen }
        XCTAssertEqual(finalRows, 2)
        XCTAssertEqual(finalAnchor, Data([1]))
        XCTAssertNil(pending)
        XCTAssertFalse(second.hasMore)
        XCTAssertTrue(second.failedTypes.isEmpty)
        // round2 H-N1：fixture 样本为 2023 年，落 history 道；recent 道只在首轮探到空页，在途批次续其所在道
        XCTAssertEqual(requests.filter { $0.scope.lane == .history }.map(\.anchor), [nil, Data([1])],
                       "Resume fetching after the staged page, not the old committed cursor")
        XCTAssertEqual(requests.filter { $0.scope.lane == .recent }.count, 1, "A pending history batch must not re-probe recent")
        XCTAssertTrue(requests.allSatisfy { $0.limit == 500 })
    }

    func test_historyPagesPublishCompleteWindowsBeforeTheFinalCheckpoint() async throws {
        let (db, imports, binding) = try await makeStore()
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .bloodOxygen, start: start, end: start.addingTimeInterval(86400))
        let samples = (0..<501).map { offset in
            let at = start.addingTimeInterval(Double(offset))
            return HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch", start: at, end: at)
        }
        let rows = samples.map {
            DeviceMetricRow(metricKey: "blood_oxygen", value: 98, unit: "%", measuredAt: $0.end,
                sourceRef: HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: $0.id, ordinal: nil))
        }
        let provider = HealthSyncFixtureProvider(kind: .bloodOxygen, pages: [
            HealthChangeBatch(added: Array(samples.prefix(500)), deleted: [], anchor: Data([1]), hasMore: true),
            HealthChangeBatch(added: [samples[500]], deleted: [], anchor: Data([2]), hasMore: false)
        ], snapshots: [HealthWindowSnapshot(window: window, samples: samples, rows: rows)])
        let sync = service(db, imports: imports, provider: provider)
        let first = try await sync.performSync(quietStart: "22:00", quietEnd: "07:00")
        let interimAnchor = try await imports.anchor(binding: binding, kind: .bloodOxygen)
        let staged = try await imports.pendingBatch(binding: binding, kind: .bloodOxygen)
        let interimRows = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(first.receivedChanges, 500)
        XCTAssertEqual(interimRows, 501, "A complete current window is visible while historical paging continues")
        XCTAssertNil(interimAnchor)
        XCTAssertEqual(staged?.batch.added.count, 500)
        XCTAssertTrue(first.hasMore)
        let dashboard = try await imports.dashboard()
        XCTAssertEqual(dashboard.types.first { $0.kind == .bloodOxygen }?.rowCount, 501)

        let second = try await sync.performSync(quietStart: "22:00", quietEnd: "07:00")
        let finalRows = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        let finalAnchor = try await imports.anchor(binding: binding, kind: .bloodOxygen)
        XCTAssertEqual(second.receivedChanges, 1)
        XCTAssertEqual(finalRows, 501)
        XCTAssertEqual(finalAnchor, Data([2]))
        XCTAssertFalse(second.hasMore)
    }

    func test_fullAddedPageWithDeletionDoesNotGetStuckAtStaging() async throws {
        let (_, imports, binding) = try await makeStore()
        let samples = discreteFixture(days: 500).samples
        let pending = try await imports.stage(binding: binding, kind: .bloodOxygen, previousAnchor: nil,
            page: .init(added: samples, deleted: [UUID()], anchor: Data([9]), hasMore: true))
        XCTAssertEqual(pending.batch.added.count, 500)
        XCTAssertEqual(pending.batch.deleted.count, 1)
    }

    func test_dashboardReportIsDurableAndBoundToTheConnection() async throws {
        let (db, imports, binding) = try await makeStore()
        let provider = HealthSyncFixtureProvider(kind: .heartRate, pages: [], snapshots: [])
        let sync = service(db, imports: imports, provider: provider)
        _ = try await sync.performSync(quietStart: "22:00", quietEnd: "07:00")
        let reloaded = try await HealthImportStore(writer: db.writer).dashboard()
        XCTAssertEqual(reloaded.lastReport?.bindingId, binding.id)
        try await db.writer.write { try $0.execute(sql: "DELETE FROM hk_import_binding") }
        let next = try await imports.connect()
        let dashboard = try await imports.dashboard()
        XCTAssertNotEqual(next.id, binding.id)
        XCTAssertNil(dashboard.lastReport, "A reconnect must not display the preceding binding's report")
    }

    func test_windowBudgetKeepsCheckpointUntilRemainingWindowsResume() async throws {
        let (db, imports, binding) = try await makeStore()
        let fixture = discreteFixture(days: 64)
        let provider = HealthSyncFixtureProvider(kind: .bloodOxygen,
            pages: [HealthChangeBatch(added: fixture.samples, deleted: [], anchor: Data([1]), hasMore: false)],
            snapshots: fixture.snapshots)
        let sync = service(db, imports: imports, provider: provider)
        var report = try await sync.performSync(quietStart: "22:00", quietEnd: "07:00")
        let interimAnchor = try await imports.anchor(binding: binding, kind: .bloodOxygen)
        let interimRows = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") ?? 0 }
        XCTAssertGreaterThan(interimRows, 0)
        XCTAssertLessThan(interimRows, 64)
        XCTAssertNil(interimAnchor)
        for _ in 0..<64 where report.hasMore {
            report = try await sync.performSync(quietStart: "22:00", quietEnd: "07:00")
        }
        let finalAnchor = try await imports.anchor(binding: binding, kind: .bloodOxygen)
        let finalRows = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        let queriedWindows = await provider.queriedWindows
        XCTAssertFalse(report.hasMore)
        XCTAssertEqual(finalAnchor, Data([1]))
        XCTAssertEqual(finalRows, 64)
        XCTAssertEqual(queriedWindows.count, 64, "An empty next page must not invalidate completed windows")
    }

    func test_cancelledCallerCannotStartOrStageFlight() async throws {
        let (db, imports, binding) = try await makeStore()
        let provider = HealthSyncFixtureProvider(kind: .heartRate, pages: [], snapshots: [])
        let sync = service(db, imports: imports, provider: provider)
        let gate = HealthSyncTestGate()
        let work = Task {
            await gate.wait()
            return try await sync.performSync(quietStart: "22:00", quietEnd: "07:00")
        }
        work.cancel()
        await gate.open()
        do {
            _ = try await work.value
            XCTFail("A cancelled background caller must not create an uncancelled flight")
        } catch is CancellationError { }
        let requests = await provider.requests
        let pending = try await imports.pendingBatch(binding: binding, kind: .heartRate)
        let anchor = try await imports.anchor(binding: binding, kind: .heartRate)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(pending)
        XCTAssertNil(anchor)
    }

    func test_unreadableWindowsDoNotStarveLaterReadableWindows() async throws {
        let (db, imports, binding) = try await makeStore()
        let fixture = discreteFixture(days: 40)
        let provider = HealthSyncFixtureProvider(kind: .bloodOxygen,
            pages: [HealthChangeBatch(added: fixture.samples, deleted: [], anchor: Data([1]), hasMore: false)],
            snapshots: fixture.snapshots)
        await provider.failSnapshots(Set(fixture.snapshots.prefix(33).map(\.window)))
        let sync = service(db, imports: imports, provider: provider)
        var rows = 0
        for _ in 0..<40 where rows < 7 {
            _ = try await sync.performSync(quietStart: "22:00", quietEnd: "07:00")
            rows = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") ?? 0 }
        }
        let anchor = try await imports.anchor(binding: binding, kind: .bloodOxygen)
        let pending = try await imports.pendingBatch(binding: binding, kind: .bloodOxygen)
        XCTAssertEqual(rows, 7, "Retrying unreadable old windows must not permanently starve readable later windows")
        XCTAssertNil(anchor)
        XCTAssertNotNil(pending)
    }

    func test_cancellingFlightOwnerPropagatesToItsQueries() async throws {
        let (db, imports, binding) = try await makeStore()
        let entered = HealthSyncTestGate()
        let release = HealthSyncTestGate()
        let provider = HealthSyncFixtureProvider(kind: .heartRate, pages: [], snapshots: [], entered: entered, release: release)
        let sync = service(db, imports: imports, provider: provider)
        let owner = Task { try await sync.performSync(quietStart: "22:00", quietEnd: "07:00") }
        await entered.wait()
        owner.cancel()
        await release.open()
        do {
            _ = try await owner.value
            XCTFail("Cancelling the owner must cancel its unstructured query task")
        } catch is CancellationError { }
        let anchor = try await imports.anchor(binding: binding, kind: .heartRate)
        XCTAssertNil(anchor)
    }

    func test_cancellingAnotherCallerDoesNotCancelActiveOwner() async throws {
        let (db, imports, binding) = try await makeStore()
        let entered = HealthSyncTestGate()
        let release = HealthSyncTestGate()
        let provider = HealthSyncFixtureProvider(kind: .heartRate, pages: [], snapshots: [], entered: entered, release: release)
        let sync = service(db, imports: imports, provider: provider)
        let owner = Task { try await sync.performSync(quietStart: "22:00", quietEnd: "07:00") }
        await entered.wait()
        let waiter = Task { try await sync.performSync(quietStart: "22:00", quietEnd: "07:00") }
        await Task.yield()
        waiter.cancel()
        await release.open()
        let report = try await owner.value
        do {
            _ = try await waiter.value
            XCTFail("The cancelled caller must observe its own cancellation")
        } catch is CancellationError { }
        let anchor = try await imports.anchor(binding: binding, kind: .heartRate)
        XCTAssertTrue(report.failedTypes.isEmpty)
        XCTAssertNotNil(anchor, "A cancelled coalesced caller cannot kill another caller's flight")
    }

    // MARK: - round2 H3 / H-N1 / H-N2：开关关闭独立失败态、近一年优先双道回填、进度报告

    /// round2 H3/H-N4：开关关闭是独立失败态，不得与「缺本人档案」混为 missingOwner
    /// （视图层三态文案依赖错误分型）。
    func test_runThrowsDisabledNotMissingOwnerWhenToggleOff() async throws {
        let (db, imports, _) = try await makeStore()
        let provider = HealthSyncFixtureProvider(kind: .steps, pages: [], snapshots: [])
        let sync = service(db, imports: imports, provider: provider)
        try await db.writer.write { try $0.execute(sql: "INSERT OR REPLACE INTO app_settings (key, value) VALUES ('authHealthRead', 'false')") }
        do {
            _ = try await sync.performSync(quietStart: "22:00", quietEnd: "07:00")
            XCTFail("expected disabled")
        } catch HealthImportStore.ImportError.disabled { }
        let requests = await provider.requests
        XCTAssertTrue(requests.isEmpty, "A disabled toggle must not query HealthKit at all")
    }

    /// round2 H-N1：每类先探 recent 道（近一年最新优先），空页后才探 history；报告回传当前道与剩余窗口。
    func test_recentLaneIsProbedBeforeHistoryAndProgressIsReported() async throws {
        let (db, imports, binding) = try await makeStore()
        let fixture = discreteFixture(days: 40)   // 2023 年样本 → history 道；40 窗 > 每轮 32 预算
        let provider = HealthSyncFixtureProvider(kind: .bloodOxygen,
            pages: [HealthChangeBatch(added: fixture.samples, deleted: [], anchor: Data([1]), hasMore: false)],
            snapshots: fixture.snapshots)
        let sync = service(db, imports: imports, provider: provider)
        let report = try await sync.performSync(quietStart: "22:00", quietEnd: "07:00")
        let lanes = await provider.requests.filter { $0.kind == .bloodOxygen }.map(\.scope.lane)
        XCTAssertEqual(lanes, [.recent, .history], "recent 空页后才探 history，且有工作即停止探测")
        XCTAssertEqual(report.backfillLane, .history)
        XCTAssertEqual(report.remainingWindows, 8, "40 窗 − 本轮 32 窗 = 8 窗待物化")
        XCTAssertTrue(report.hasMore)
        XCTAssertEqual(report.sparseWindows, 0)
        let recentAnchor = try await imports.anchor(binding: binding, kind: .bloodOxygen, lane: .recent)
        let historyAnchor = try await imports.anchor(binding: binding, kind: .bloodOxygen, lane: .history)
        XCTAssertNotNil(recentAnchor, "空的 recent 道立即落检查点")
        XCTAssertNil(historyAnchor, "history 道排空前不推进游标")
        // 两道游标键互不串扰（recent 道 v4 降序首填空间 / history 道 hk.v3）
        let keys = try await db.writer.read { try String.fetchAll($0, sql: "SELECT anchor_key FROM hk_sync_anchor WHERE anchor_key LIKE ? ORDER BY anchor_key", arguments: ["hk.v4.\(binding.id.uuidString).bloodOxygen.%"]) }
        XCTAssertEqual(keys, ["hk.v4.\(binding.id.uuidString).bloodOxygen.recent"])
        // 排空后 history 道游标落地、进度归零
        var last = report
        for _ in 0..<8 where last.hasMore { last = try await sync.performSync(quietStart: "22:00", quietEnd: "07:00") }
        XCTAssertFalse(last.hasMore)
        XCTAssertEqual(last.remainingWindows, 0)
        let drainedAnchor = try await imports.anchor(binding: binding, kind: .bloodOxygen, lane: .history)
        XCTAssertEqual(drainedAnchor, Data([1]))
    }

    /// round2 H-N2：稀疏窗计数经快照上送到报告（统计事实，非阈值判定）。
    func test_sparseWindowsFromSnapshotsAreReported() async throws {
        let (db, imports, _) = try await makeStore()
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .heartRate, start: start, end: start.addingTimeInterval(3600))
        let sample = HealthSampleReference(id: UUID(), kind: .heartRate, sourceID: "watch",
                                           start: start.addingTimeInterval(60), end: start.addingTimeInterval(120))
        let provider = HealthSyncFixtureProvider(kind: .heartRate,
            pages: [HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false)],
            snapshots: [HealthWindowSnapshot(window: window, samples: [sample], rows: [], sparseWindows: 1)])
        let report = try await service(db, imports: imports, provider: provider).performSync(quietStart: "22:00", quietEnd: "07:00")
        XCTAssertEqual(report.sparseWindows, 1)
        XCTAssertTrue(report.failedTypes.isEmpty, "稀疏不是失败")
    }

    /// `report_json` 旧 JSON 无新键必须可解码——新字段全部 Optional（合成 Decodable 对非 Optional 缺键即抛）。
    func test_syncReportDecodesLegacyJSONWithoutNewKeys() throws {
        let legacy = #"{"elevated":0,"noRangeCount":0,"persistedRows":3,"preservedRows":0,"deferredWindows":0,"receivedChanges":3,"rejectedSamples":0,"failedTypes":[],"hasMore":false,"notificationFailures":0,"lastSyncAt":0}"#
        let report = try JSONDecoder().decode(SyncReport.self, from: Data(legacy.utf8))
        XCTAssertNil(report.sparseWindows)
        XCTAssertNil(report.remainingWindows)
        XCTAssertNil(report.backfillLane)
        XCTAssertEqual(report.persistedRows, 3)
        var full = report
        full.sparseWindows = 2; full.remainingWindows = 5; full.backfillLane = .history
        let roundTrip = try JSONDecoder().decode(SyncReport.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(roundTrip, full)
    }
}

// 审查修复（2026-09-18）：history 道默认便捷已收敛至
// HealthImportTestSupport.swift 单一出口（本文件原为两份逐字重复之一）

private actor HealthSyncTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    /// 睡眠零归并行回归（2026-09-20 业主真机复测「最近数据仍缺失」）：watch 迟到
    /// 样本并入后 unspecified 段归零消失——窗口派生聚合行的重算即权威，旧键行
    /// 可删、窗口照常判完整、锚点推进（此前 complete=false 永久冻结 → 该类型
    /// 此后再无新数据）。
    func test_sleepZeroMergedRowsDoNotFreezeTheWindow() async throws {
        let (db, imports, binding) = try await makeStore()
        let windowStart = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .sleep, start: windowStart, end: windowStart.addingTimeInterval(86_400))
        let phoneSample = HealthSampleReference(id: UUID(), kind: .sleep, sourceID: "phone",
            start: windowStart.addingTimeInterval(600), end: windowStart.addingTimeInterval(2_600))
        let watchSample = HealthSampleReference(id: UUID(), kind: .sleep, sourceID: "watch",
            start: windowStart.addingTimeInterval(600), end: windowStart.addingTimeInterval(2_600))
        func sleepRow(_ key: String, _ value: Double) -> DeviceMetricRow {
            DeviceMetricRow(metricKey: key, value: value, unit: "h", measuredAt: windowStart,
                sourceRef: window.prefix + key, aggregation: .sleepDuration, windowEnd: window.end)
        }
        // 第一轮：仅手机 unspecified 样本 → total + unspecified 两行
        let first = HealthWindowSnapshot(window: window, samples: [phoneSample],
            rows: [sleepRow("sleep_total", 8.0), sleepRow("sleep_unspecified", 8.0)])
        // 第二轮：watch 样本并入 → 合并语义把 unspecified 归零（行消失）
        let second = HealthWindowSnapshot(window: window, samples: [phoneSample, watchSample],
            rows: [sleepRow("sleep_total", 8.0), sleepRow("sleep_core", 6.0), sleepRow("sleep_rem", 2.0)])
        let provider = HealthSyncFixtureProvider(kind: .sleep, pages: [
            HealthChangeBatch(added: [phoneSample], deleted: [], anchor: Data([1]), hasMore: false),
            HealthChangeBatch(added: [watchSample], deleted: [], anchor: Data([2]), hasMore: false),
        ], snapshots: [first], snapshotQueues: [window: [first, second]])
        let sync = service(db, imports: imports, provider: provider)

        let round1 = try await sync.performSync(quietStart: "22:00", quietEnd: "07:00")
        let rows1 = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(round1.receivedChanges, 1)
        XCTAssertEqual(rows1, 2, "首轮：total + unspecified 两行落库")
        XCTAssertEqual(try await imports.anchor(binding: binding, kind: .sleep), Data([1]))

        let round2 = try await sync.performSync(quietStart: "22:00", quietEnd: "07:00")
        let rows2 = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(round2.receivedChanges, 1)
        XCTAssertEqual(rows2, 3, "次轮：归零的 unspecified 旧行删除（2-1），新 staged 行落库（+2）= 3")
        XCTAssertEqual(try await imports.anchor(binding: binding, kind: .sleep), Data([2]),
            "窗口照常判完整 → 锚点推进（此前永久冻结、最近数据缺失）")
        let unspecified = try await db.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample WHERE source_ref LIKE '%sleep_unspecified'") ?? 0
        }
        XCTAssertEqual(unspecified, 0, "归零键行必须删除——合并后的总量行才是该窗口真相")
    }

}
private actor HealthSyncFixtureProvider: HealthReadingProvider {
    struct Request: Sendable {
        let kind: HealthDataKind
        let scope: HealthFetchScope
        let anchor: Data?
        let limit: Int
    }
    enum Failure: Error { case unexpectedCursor, oversizedQuery, unavailableWindow }
    let kind: HealthDataKind
    let pages: [HealthChangeBatch]
    let snapshots: [HealthImportWindow: HealthWindowSnapshot]
    let entered: HealthSyncTestGate?
    let release: HealthSyncTestGate?
    private var failingWindows: Set<HealthImportWindow> = []
    /// 逐窗口快照序列（2026-09-20 睡眠零归并回归测试用）：命中即出队，
    /// 队列空后回落 snapshots 固定表。
    private var snapshotQueues: [HealthImportWindow: [HealthWindowSnapshot]] = [:]
    private(set) var requests: [Request] = []
    private(set) var queriedWindows: [HealthImportWindow] = []

    init(kind: HealthDataKind, pages: [HealthChangeBatch], snapshots: [HealthWindowSnapshot],
         entered: HealthSyncTestGate? = nil, release: HealthSyncTestGate? = nil,
         snapshotQueues: [HealthImportWindow: [HealthWindowSnapshot]] = [:]) {
        self.kind = kind; self.pages = pages
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.window, $0) })
        self.entered = entered; self.release = release
        self.snapshotQueues = snapshotQueues
    }

    func isAvailable() -> Bool { true }
    func requestAuthorization() {}
    func failSnapshots(_ windows: Set<HealthImportWindow>) { failingWindows = windows }

    /// round2 H-N1：只在「首页首样本所属道」供页（模拟 HealthKit 分道谓词——另一道恒空页）；
    /// 无样本的纯删除页/空 fixture 归 recent 道。
    func changes(for kind: HealthDataKind, scope: HealthFetchScope, anchor: Data?, limit: Int) async throws -> HealthChangeBatch {
        requests.append(Request(kind: kind, scope: scope, anchor: anchor, limit: limit))
        guard limit == 500 else { throw Failure.oversizedQuery }
        let lane: HealthFetchLane
        if let sample = pages.first?.added.first {
            lane = scope.matches(sample) ? scope.lane : (scope.lane == .recent ? .history : .recent)
        } else {
            lane = .recent
        }
        if kind == self.kind, scope.lane == lane {
            await entered?.open()
            await release?.wait()
            try Task.checkCancellation()
            if !pages.isEmpty {
                if anchor == nil { return pages[0] }
                guard let index = pages.firstIndex(where: { $0.anchor == anchor }) else { throw Failure.unexpectedCursor }
                if index + 1 < pages.count { return pages[index + 1] }
            }
        }
        return HealthChangeBatch(added: [], deleted: [], anchor: anchor ?? Data("\(kind.rawValue).\(scope.lane.rawValue)".utf8), hasMore: false)
    }

    func snapshot(for window: HealthImportWindow, calendar: Calendar) throws -> HealthWindowSnapshot {
        queriedWindows.append(window)
        if var queue = snapshotQueues[window], !queue.isEmpty {
            let next = queue.removeFirst()
            snapshotQueues[window] = queue
            return next
        }
        guard !failingWindows.contains(window), let snapshot = snapshots[window] else { throw Failure.unavailableWindow }
        return snapshot
    }
}


// 睡眠零归并行回归（2026-09-20 业主真机复测「最近数据仍缺失」）——extension 承载：
// 文件尾部追加避免类内插入的括号手术（族 J 教训：手术脚本比问题本身更危险）。
// watch 迟到样本并入后 unspecified 段归零消失——窗口派生聚合行的重算即权威，
// 旧键行可删、窗口照常判完整、锚点推进（此前 complete=false 永久冻结）。
extension HealthKitSyncServiceTests {
    func test_sleepZeroMergedRowsDoNotFreezeTheWindow() async throws {
        let (db, imports, binding) = try await makeStore()
        let windowStart = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .sleep, start: windowStart, end: windowStart.addingTimeInterval(86_400))
        let phoneSample = HealthSampleReference(id: UUID(), kind: .sleep, sourceID: "phone",
            start: windowStart.addingTimeInterval(600), end: windowStart.addingTimeInterval(2_600))
        let watchSample = HealthSampleReference(id: UUID(), kind: .sleep, sourceID: "watch",
            start: windowStart.addingTimeInterval(600), end: windowStart.addingTimeInterval(2_600))
        func sleepRow(_ key: String, _ value: Double) -> DeviceMetricRow {
            DeviceMetricRow(metricKey: key, value: value, unit: "h", measuredAt: windowStart,
                sourceRef: window.prefix + key, aggregation: .sleepDuration, windowEnd: window.end)
        }
        // 第一轮：仅手机 unspecified 样本 → total + unspecified 两行
        let first = HealthWindowSnapshot(window: window, samples: [phoneSample],
            rows: [sleepRow("sleep_total", 8.0), sleepRow("sleep_unspecified", 8.0)])
        // 第二轮：watch 样本并入 → 合并语义把 unspecified 归零（行消失）
        let second = HealthWindowSnapshot(window: window, samples: [phoneSample, watchSample],
            rows: [sleepRow("sleep_total", 8.0), sleepRow("sleep_core", 6.0), sleepRow("sleep_rem", 2.0)])
        let provider = HealthSyncFixtureProvider(kind: .sleep, pages: [
            HealthChangeBatch(added: [phoneSample], deleted: [], anchor: Data([1]), hasMore: false),
            HealthChangeBatch(added: [watchSample], deleted: [], anchor: Data([2]), hasMore: false),
        ], snapshots: [first], snapshotQueues: [window: [first, second]])
        let sync = service(db, imports: imports, provider: provider)

        let round1 = try await sync.performSync(quietStart: "22:00", quietEnd: "07:00")
        let rows1 = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(round1.receivedChanges, 1)
        XCTAssertEqual(rows1, 2, "首轮：total + unspecified 两行落库")
        XCTAssertEqual(try await imports.anchor(binding: binding, kind: .sleep), Data([1]))

        let round2 = try await sync.performSync(quietStart: "22:00", quietEnd: "07:00")
        let rows2 = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(round2.receivedChanges, 1)
        XCTAssertEqual(rows2, 3, "次轮：归零的 unspecified 旧行删除（2-1），新 staged 行落库（+2）= 3")
        XCTAssertEqual(try await imports.anchor(binding: binding, kind: .sleep), Data([2]),
            "窗口照常判完整 → 锚点推进（此前永久冻结、最近数据缺失）")
        let unspecified = try await db.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample WHERE source_ref LIKE '%sleep_unspecified'") ?? 0
        }
        XCTAssertEqual(unspecified, 0, "归零键行必须删除——合并后的总量行才是该窗口真相")
    }
}
