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
        let db = try GRDBStore.inMemory()
        let patient = UUID()
        try await db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, 'Owner', 'self', 0, 0)
                """, arguments: [patient.uuidString])
            try db.execute(sql: """
                INSERT INTO local_owner (id, display_name, self_patient_id, created_at)
                VALUES (?, 'Owner', ?, 0)
                """, arguments: [UUID().uuidString, patient.uuidString])
        }
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
        XCTAssertEqual(requests.map(\.anchor), [nil, Data([1])], "Resume fetching after the staged page, not the old committed cursor")
        XCTAssertTrue(requests.allSatisfy { $0.limit == 500 })
    }

    func test_changePagesAreDurableBeforeAnyWindowReconciliation() async throws {
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
        XCTAssertEqual(interimRows, 0)
        XCTAssertNil(interimAnchor)
        XCTAssertEqual(staged?.batch.added.count, 500)
        XCTAssertTrue(first.hasMore)

        let second = try await sync.performSync(quietStart: "22:00", quietEnd: "07:00")
        let finalRows = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        let finalAnchor = try await imports.anchor(binding: binding, kind: .bloodOxygen)
        XCTAssertEqual(second.receivedChanges, 1)
        XCTAssertEqual(finalRows, 501)
        XCTAssertEqual(finalAnchor, Data([2]))
        XCTAssertFalse(second.hasMore)
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
}

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
}

private actor HealthSyncFixtureProvider: HealthReadingProvider {
    struct Request: Sendable {
        let kind: HealthDataKind
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
    private(set) var requests: [Request] = []
    private(set) var queriedWindows: [HealthImportWindow] = []

    init(kind: HealthDataKind, pages: [HealthChangeBatch], snapshots: [HealthWindowSnapshot],
         entered: HealthSyncTestGate? = nil, release: HealthSyncTestGate? = nil) {
        self.kind = kind; self.pages = pages
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.window, $0) })
        self.entered = entered; self.release = release
    }

    func isAvailable() -> Bool { true }
    func requestAuthorization() {}
    func failSnapshots(_ windows: Set<HealthImportWindow>) { failingWindows = windows }

    func changes(for kind: HealthDataKind, anchor: Data?, limit: Int) async throws -> HealthChangeBatch {
        requests.append(Request(kind: kind, anchor: anchor, limit: limit))
        guard limit == 500 else { throw Failure.oversizedQuery }
        if kind == self.kind {
            await entered?.open()
            await release?.wait()
            try Task.checkCancellation()
            if !pages.isEmpty {
                if anchor == nil { return pages[0] }
                guard let index = pages.firstIndex(where: { $0.anchor == anchor }) else { throw Failure.unexpectedCursor }
                if index + 1 < pages.count { return pages[index + 1] }
            }
        }
        return HealthChangeBatch(added: [], deleted: [], anchor: anchor ?? Data(kind.rawValue.utf8), hasMore: false)
    }

    func snapshot(for window: HealthImportWindow, calendar: Calendar) throws -> HealthWindowSnapshot {
        queriedWindows.append(window)
        guard !failingWindows.contains(window), let snapshot = snapshots[window] else { throw Failure.unavailableWindow }
        return snapshot
    }
}
