import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure

// binds: SU-M2-F16
@MainActor
final class HealthImportAcceptanceTests: XCTestCase {
    private func makeStore() async throws -> (GRDBStore, HealthImportStore, UUID) {
        let db = try GRDBStore.inMemory()
        let patient = UUID()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'Owner', 'self', 0, 0)", arguments: [patient.uuidString])
            try db.execute(sql: "INSERT INTO local_owner (id, display_name, self_patient_id, created_at) VALUES (?, 'Owner', ?, 0)", arguments: [UUID().uuidString, patient.uuidString])
        }
        return (db, HealthImportStore(writer: db.writer), patient)
    }

    private func checkpoint(_ store: HealthImportStore, binding: HealthImportStore.Binding,
                            kind: HealthDataKind, previousAnchor: Data?, batch: HealthChangeBatch,
                            snapshots: [HealthWindowSnapshot]) async throws -> HealthImportStore.CommitReport {
        let pending = try await store.stage(binding: binding, kind: kind, previousAnchor: previousAnchor, page: batch)
        return try await store.commit(binding: binding, kind: kind, pending: pending, snapshots: snapshots)
    }

    func test_connectionUsesOwnerAndKeepsItsTimeZone() async throws {
        let (_, store, patient) = try await makeStore()
        let first = try await store.connect(timeZoneID: "Asia/Shanghai")
        let second = try await store.connect(timeZoneID: "America/New_York")
        XCTAssertEqual(first.patientId, patient)
        XCTAssertEqual(first, second)
        XCTAssertEqual(second.timeZoneID, "Asia/Shanghai")
    }

    func test_checkpointAndDeletionAreCommittedWithTheProjection() async throws {
        let (db, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .bloodOxygen, start: start, end: start.addingTimeInterval(86400))
        let sample = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch",
                                           start: start.addingTimeInterval(60), end: start.addingTimeInterval(60))
        let row = DeviceMetricRow(metricKey: "blood_oxygen", value: 98, unit: "%",
                                  measuredAt: sample.end, sourceRef: HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: sample.id, ordinal: nil),
                                  sourceIdentifier: "watch", aggregation: .sample, windowEnd: sample.end)
        _ = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: nil,
            batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [sample], rows: [row])])
        let deleted = HealthChangeBatch(added: [], deleted: [sample.id], anchor: Data([2]), hasMore: false)
        let windows = try await store.affectedWindows(binding: binding, kind: .bloodOxygen, batch: deleted)
        XCTAssertEqual(windows.count, 1)
        let pending = try await store.stage(binding: binding, kind: .bloodOxygen,
                                            previousAnchor: Data([1]), page: deleted)
        do {
            _ = try await store.commit(binding: binding, kind: .bloodOxygen, pending: pending, snapshots: [])
            XCTFail("A known deletion must reconcile its affected window before advancing")
        } catch HealthImportStore.ImportError.incompleteSnapshot { }
        _ = try await store.commit(binding: binding, kind: .bloodOxygen, pending: pending,
            snapshots: [HealthWindowSnapshot(window: window, samples: [], rows: [])])
        let count = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        let anchor = try await store.anchor(binding: binding, kind: .bloodOxygen)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(anchor, Data([2]))
    }

    func test_emptyReadDoesNotDeleteKnownDataOrAdvanceCursor() async throws {
        let (db, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .bloodOxygen, start: start, end: start.addingTimeInterval(86400))
        let sample = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch", start: start, end: start)
        let row = DeviceMetricRow(metricKey: "blood_oxygen", value: 98, unit: "%",
                                  measuredAt: start, sourceRef: HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: sample.id, ordinal: nil))
        _ = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: nil,
            batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [sample], rows: [row])])
        do {
            _ = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: Data([1]),
                batch: HealthChangeBatch(added: [], deleted: [], anchor: Data([2]), hasMore: false),
                snapshots: [HealthWindowSnapshot(window: window, samples: [], rows: [])])
            XCTFail("Unknown read visibility must not erase imported data")
        } catch HealthImportStore.ImportError.incompleteSnapshot { }
        let count = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        let anchor = try await store.anchor(binding: binding, kind: .bloodOxygen)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(anchor, Data([1]))
    }

    func test_revokingAppPermissionRejectsInFlightCommit() async throws {
        let (db, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let pending = try await store.stage(binding: binding, kind: .heartRate, previousAnchor: nil,
            page: HealthChangeBatch(added: [], deleted: [], anchor: Data([1]), hasMore: false))
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO app_settings (key, value) VALUES ('authHealthRead', 'false')")
        }
        do {
            _ = try await store.commit(binding: binding, kind: .heartRate, pending: pending, snapshots: [])
            XCTFail("Revocation must be checked again at the transaction boundary")
        } catch HealthImportStore.ImportError.disabled { }
        let anchor = try await store.anchor(binding: binding, kind: .heartRate)
        XCTAssertNil(anchor)
    }

    func test_missingAddedSampleSnapshotCannotAdvanceCheckpoint() async throws {
        let (_, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let time = Date(timeIntervalSince1970: 1_700_006_400)
        let sample = HealthSampleReference(id: UUID(), kind: .heartRate, sourceID: "watch", start: time, end: time)
        do {
            _ = try await checkpoint(store, binding: binding, kind: .heartRate, previousAnchor: nil,
                batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
                snapshots: [])
            XCTFail("A cursor must never acknowledge an unprocessed addition")
        } catch HealthImportStore.ImportError.incompleteSnapshot { }
        let anchor = try await store.anchor(binding: binding, kind: .heartRate)
        XCTAssertNil(anchor)
    }

    func test_emptySnapshotAfterTombstonePreservesUntombstonedSample() async throws {
        let (db, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .bloodOxygen, start: start, end: start.addingTimeInterval(86400))
        let a = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch",
                                      start: start.addingTimeInterval(60), end: start.addingTimeInterval(60))
        let b = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch",
                                      start: start.addingTimeInterval(120), end: start.addingTimeInterval(120))
        let rows = [a, b].map {
            DeviceMetricRow(metricKey: "blood_oxygen", value: 98, unit: "%", measuredAt: $0.end,
                            sourceRef: HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: $0.id, ordinal: nil),
                            sourceIdentifier: "watch", aggregation: .sample, windowEnd: $0.end)
        }
        _ = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: nil,
            batch: HealthChangeBatch(added: [a, b], deleted: [], anchor: Data([1]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [a, b], rows: rows)])
        // Permission can disappear after the anchored query. B has no deletion evidence.
        let page = HealthChangeBatch(added: [], deleted: [a.id], anchor: Data([2]), hasMore: false)
        let result = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: Data([1]),
            batch: page, snapshots: [HealthWindowSnapshot(window: window, samples: [], rows: [])])
        let count = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        let index = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hk_sample_index") }
        let anchor = try await store.anchor(binding: binding, kind: .bloodOxygen)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(index, 2, "Incomplete windows retain the references needed for later tombstones")
        XCTAssertEqual(anchor, Data([1]))
        XCTAssertEqual(result.deferredWindows, 1)
        XCTAssertTrue(result.hasMore)

        let restarted = HealthImportStore(writer: db.writer)
        let loaded = try await restarted.pendingBatch(binding: binding, kind: .bloodOxygen)
        let pending = try XCTUnwrap(loaded)
        let resumed = try await restarted.commit(binding: binding, kind: .bloodOxygen, pending: pending,
            snapshots: [HealthWindowSnapshot(window: window, samples: [b], rows: [rows[1]])])
        let remaining = try await db.writer.read { try String.fetchAll($0, sql: "SELECT sample_id FROM hk_sample_index") }
        let finalAnchor = try await restarted.anchor(binding: binding, kind: .bloodOxygen)
        XCTAssertEqual(remaining, [b.id.uuidString])
        XCTAssertEqual(finalAnchor, Data([2]))
        XCTAssertFalse(resumed.hasMore)
    }

    /// P1（二轮复审）：恢复备份后 hk_sample_index 为空；重连后本机 HealthKit 只暴露 B。
    /// 非空快照不得删除未被索引证明来自本连接的 A（恢复的医疗事实保留），B 按同身份重放。
    func test_reconnectAfterRestoreKeepsUnindexedRestoredReadings() async throws {
        let (db, store, patient) = try await makeStore()
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .bloodOxygen, start: start, end: start.addingTimeInterval(86400))
        let a = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch",
                                      start: start.addingTimeInterval(60), end: start.addingTimeInterval(60))
        let b = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch",
                                      start: start.addingTimeInterval(120), end: start.addingTimeInterval(120))
        // Restored projections: rows exist, index/binding/anchors were cleared by the restore path.
        try await db.writer.write { db in
            for sample in [a, b] {
                try db.execute(sql: """
                    INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, excluded,
                      source_ref, source_identifier, aggregation_kind, measured_at, created_at)
                    VALUES (?, ?, 'bloodOxygen', 97, '%', 'device', 1, 0, ?, 'watch', 'sample', ?, 0)
                    """, arguments: [UUID().uuidString, patient.uuidString,
                                     HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: sample.id, ordinal: nil),
                                     sample.end.timeIntervalSince1970])
            }
        }
        let binding = try await store.connect(timeZoneID: "UTC")
        let bRow = DeviceMetricRow(metricKey: "blood_oxygen", value: 99, unit: "%", measuredAt: b.end,
                                   sourceRef: HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: b.id, ordinal: nil),
                                   sourceIdentifier: "watch", aggregation: .sample, windowEnd: b.end)
        _ = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: nil,
            batch: HealthChangeBatch(added: [b], deleted: [], anchor: Data([1]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [b], rows: [bRow])])
        let values = try await db.writer.read { db in
            try Double.fetchAll(db, sql: "SELECT value FROM metric_sample ORDER BY measured_at")
        }
        XCTAssertEqual(values, [97, 99], "A (restored, unindexed) survives; B is replayed onto its existing row")
        // Once B is indexed by this connection, its later deletion is honoured while A still survives.
        _ = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: Data([1]),
            batch: HealthChangeBatch(added: [], deleted: [b.id], anchor: Data([2]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [], rows: [])])
        let remaining = try await db.writer.read { db in
            try Double.fetchAll(db, sql: "SELECT value FROM metric_sample")
        }
        XCTAssertEqual(remaining, [97])
    }

    /// 同一样本身份重放（值/来源元数据更新）必须保留用户的排除态（§5.29 软删不被同步覆盖）。
    func test_checkpointReplayDoesNotChangeExcludedRows() async throws {
        let (db, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .bloodOxygen, start: start, end: start.addingTimeInterval(86400))
        let sample = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch",
                                           start: start.addingTimeInterval(60), end: start.addingTimeInterval(60))
        let identity = HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: sample.id, ordinal: nil)
        func row(_ value: Double) -> DeviceMetricRow {
            DeviceMetricRow(metricKey: "blood_oxygen", value: value, unit: "%", measuredAt: sample.end,
                            sourceRef: identity, sourceIdentifier: "watch", aggregation: .sample, windowEnd: sample.end)
        }
        _ = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: nil,
            batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [sample], rows: [row(96)])])
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE metric_sample SET excluded = 1 WHERE source_ref = ?", arguments: [identity])
        }
        // A later change in the same window replays the identity with a corrected value.
        let other = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch",
                                          start: start.addingTimeInterval(3600), end: start.addingTimeInterval(3600))
        let otherRow = DeviceMetricRow(metricKey: "blood_oxygen", value: 98, unit: "%", measuredAt: other.end,
                                       sourceRef: HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: other.id, ordinal: nil),
                                       sourceIdentifier: "watch", aggregation: .sample, windowEnd: other.end)
        _ = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: Data([1]),
            batch: HealthChangeBatch(added: [other], deleted: [], anchor: Data([2]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [sample, other], rows: [row(97), otherRow])])
        let rows = try await db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT value, excluded FROM metric_sample ORDER BY measured_at")
        }
        XCTAssertEqual(rows.map { $0["value"] as Double }, [97, 98])
        XCTAssertEqual(rows.map { $0["excluded"] as Int }, [1, 0], "Replay updates facts but never resurrects an excluded point")
        let count = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(count, 2)
    }

    /// Unrequested snapshots cannot acquire permission to change unrelated projections.
    func test_snapshotForUnrequestedWindowIsRejected() async throws {
        let (_, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let touched = HealthImportWindow(kind: .bloodOxygen, start: start, end: start.addingTimeInterval(86400))
        let other = HealthImportWindow(kind: .bloodOxygen, start: start.addingTimeInterval(86400),
                                       end: start.addingTimeInterval(2 * 86400))
        let sample = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch", start: start, end: start)
        let row = DeviceMetricRow(metricKey: "blood_oxygen", value: 98, unit: "%", measuredAt: start,
                                  sourceRef: HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: sample.id, ordinal: nil))
        do {
            _ = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: nil,
                batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
                snapshots: [HealthWindowSnapshot(window: touched, samples: [sample], rows: [row]),
                            HealthWindowSnapshot(window: other, samples: [], rows: [])])
            XCTFail("A snapshot outside the batch's windows is not reconciliation work")
        } catch HealthImportStore.ImportError.incompleteSnapshot { }
        let anchor = try await store.anchor(binding: binding, kind: .bloodOxygen)
        XCTAssertNil(anchor)
    }

    func test_transactionFailureRollsBackSamplesAndCursor() async throws {
        let (db, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        try await db.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_health_checkpoint BEFORE INSERT ON hk_sync_anchor
                BEGIN SELECT RAISE(ABORT, 'injected checkpoint failure'); END;
                """)
        }
        let time = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .bloodOxygen, start: time, end: time.addingTimeInterval(86400))
        let sample = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch", start: time, end: time)
        let row = DeviceMetricRow(metricKey: "blood_oxygen", value: 98, unit: "%", measuredAt: time,
                                  sourceRef: HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: sample.id, ordinal: nil))
        do {
            _ = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: nil,
                batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
                snapshots: [HealthWindowSnapshot(window: window, samples: [sample], rows: [row])])
            XCTFail("The injected DB error must fail the transaction")
        } catch is DatabaseError { }
        let counts = try await db.writer.read { db in
            try ["metric_sample", "hk_sample_index", "hk_sync_anchor", "hk_projection_state"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        XCTAssertEqual(counts, [0, 0, 0, 0])
        let loaded = try await store.pendingBatch(binding: binding, kind: .bloodOxygen)
        let pending = try XCTUnwrap(loaded, "The durable page survives a failed materialization transaction")
        try await db.writer.write { try $0.execute(sql: "DROP TRIGGER reject_health_checkpoint") }
        let replay = try await store.commit(binding: binding, kind: .bloodOxygen, pending: pending,
            snapshots: [HealthWindowSnapshot(window: window, samples: [sample], rows: [row])])
        let anchor = try await store.anchor(binding: binding, kind: .bloodOxygen)
        XCTAssertEqual(replay.persistedRows, 1)
        XCTAssertFalse(replay.hasMore)
        XCTAssertEqual(anchor, Data([1]))
    }

    func test_staged501DeletionsDrainWithoutAdvancingCommittedAnchor() async throws {
        let (db, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .bloodOxygen, start: start, end: start.addingTimeInterval(86400))
        let samples = (0..<501).map { offset in
            HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch",
                start: start.addingTimeInterval(Double(offset)), end: start.addingTimeInterval(Double(offset)))
        }
        let rows = samples.map {
            DeviceMetricRow(metricKey: "blood_oxygen", value: 98, unit: "%", measuredAt: $0.end,
                sourceRef: HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: $0.id, ordinal: nil))
        }
        _ = try await store.stage(binding: binding, kind: .bloodOxygen, previousAnchor: nil,
            page: HealthChangeBatch(added: Array(samples.prefix(500)), deleted: [], anchor: Data([1]), hasMore: true))
        let initial = try await store.stage(binding: binding, kind: .bloodOxygen, previousAnchor: Data([1]),
            page: HealthChangeBatch(added: [samples[500]], deleted: [], anchor: Data([2]), hasMore: false))
        _ = try await store.commit(binding: binding, kind: .bloodOxygen, pending: initial,
            snapshots: [HealthWindowSnapshot(window: window, samples: samples, rows: rows)])

        let first = try await store.stage(binding: binding, kind: .bloodOxygen, previousAnchor: Data([2]),
            page: HealthChangeBatch(added: [], deleted: Array(samples.prefix(500)).map(\.id), anchor: Data([3]), hasMore: true))
        do {
            _ = try await store.commit(binding: binding, kind: .bloodOxygen, pending: first,
                snapshots: [HealthWindowSnapshot(window: window, samples: [], rows: [])])
            XCTFail("Drain the deletion pages before interpreting a complete window")
        } catch HealthImportStore.ImportError.incompleteSnapshot { }
        let interimAnchor = try await store.anchor(binding: binding, kind: .bloodOxygen)
        let interimCount = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(interimAnchor, Data([2]))
        XCTAssertEqual(interimCount, 501)

        let restarted = HealthImportStore(writer: db.writer)
        let loaded = try await restarted.pendingBatch(binding: binding, kind: .bloodOxygen)
        let recovered = try XCTUnwrap(loaded)
        XCTAssertEqual(recovered.batch.anchor, Data([3]))
        XCTAssertEqual(recovered.batch.deleted.count, 500)
        let drained = try await restarted.stage(binding: binding, kind: .bloodOxygen,
            previousAnchor: recovered.batch.anchor,
            page: HealthChangeBatch(added: [], deleted: [samples[500].id], anchor: Data([4]), hasMore: false))
        let result = try await restarted.commit(binding: binding, kind: .bloodOxygen, pending: drained,
            snapshots: [HealthWindowSnapshot(window: window, samples: [], rows: [])])
        let counts = try await db.writer.read { db in
            try ["metric_sample", "hk_sample_index", "hk_pending_batch", "hk_projection_state"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        let finalAnchor = try await restarted.anchor(binding: binding, kind: .bloodOxygen)
        XCTAssertEqual(counts, [0, 0, 0, 0])
        XCTAssertEqual(result.persistedRows, 501)
        XCTAssertEqual(finalAnchor, Data([4]))
    }

    func test_crossWindowSeriesDeletionRetiresIndexAfterEveryWindow() async throws {
        for splitAcrossCommits in [false, true] {
            let (db, store, _) = try await makeStore()
            let binding = try await store.connect(timeZoneID: "UTC")
            let start = Date(timeIntervalSince1970: 1_700_006_400)
            let windows = [0.0, 3600.0].map {
                HealthImportWindow(kind: .heartRate, start: start.addingTimeInterval($0), end: start.addingTimeInterval($0 + 3600))
            }
            let sample = HealthSampleReference(id: UUID(), kind: .heartRate, sourceID: "watch",
                start: start.addingTimeInterval(60), end: start.addingTimeInterval(3660))
            let snapshots = windows.map {
                HealthWindowSnapshot(window: $0, samples: [sample], rows: [
                    DeviceMetricRow(metricKey: "heart_rate", value: 80, unit: "bpm", sampleCount: 3,
                        measuredAt: $0.start, sourceRef: $0.prefix + "watch", sourceIdentifier: "watch", aggregation: .hourlyAverage)
                ])
            }
            _ = try await checkpoint(store, binding: binding, kind: .heartRate, previousAnchor: nil,
                batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false), snapshots: snapshots)
            let pending = try await store.stage(binding: binding, kind: .heartRate, previousAnchor: Data([1]),
                page: HealthChangeBatch(added: [], deleted: [sample.id], anchor: Data([2]), hasMore: false))
            let empty = windows.map { HealthWindowSnapshot(window: $0, samples: [], rows: []) }
            if splitAcrossCommits {
                let partial = try await store.commit(binding: binding, kind: .heartRate, pending: pending, snapshots: [empty[0]])
                let indexCount = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hk_sample_index") }
                let anchor = try await store.anchor(binding: binding, kind: .heartRate)
                XCTAssertTrue(partial.hasMore)
                XCTAssertEqual(indexCount, 1)
                XCTAssertEqual(anchor, Data([1]))
                let loaded = try await store.pendingBatch(binding: binding, kind: .heartRate)
                let resumed = try XCTUnwrap(loaded)
                _ = try await store.commit(binding: binding, kind: .heartRate, pending: resumed, snapshots: [empty[1]])
            } else {
                _ = try await store.commit(binding: binding, kind: .heartRate, pending: pending, snapshots: empty)
            }
            let counts = try await db.writer.read { db in
                try ["metric_sample", "hk_sample_index", "hk_projection_state"].map {
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
                }
            }
            let anchor = try await store.anchor(binding: binding, kind: .heartRate)
            XCTAssertEqual(counts, [0, 0, 0])
            XCTAssertEqual(anchor, Data([2]))
        }
    }

    func test_restoredAggregateIsPreservedWhileOtherProjectionsProgress() async throws {
        let (db, store, patient) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let windows = [0.0, 86400.0].map {
            HealthImportWindow(kind: .steps, start: start.addingTimeInterval($0), end: start.addingTimeInterval($0 + 86400))
        }
        let restoredID = UUID()
        try await db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, excluded,
                  source_ref, aggregation_kind, measured_at, created_at)
                VALUES (?, ?, 'steps', 6000, 'count', 'device', 1, 1, ?, 'dailySum', ?, 0)
                """, arguments: [restoredID.uuidString, patient.uuidString, windows[0].prefix + "sum", start.timeIntervalSince1970])
        }
        let samples = windows.map {
            HealthSampleReference(id: UUID(), kind: .steps, sourceID: "phone",
                start: $0.start.addingTimeInterval(60), end: $0.start.addingTimeInterval(120))
        }
        let snapshots = zip(windows, samples).map { window, sample in
            HealthWindowSnapshot(window: window, samples: [sample], rows: [
                DeviceMetricRow(metricKey: "steps", value: 200, unit: "count", measuredAt: window.start,
                    sourceRef: window.prefix + "sum", aggregation: .dailySum, windowEnd: window.end)
            ])
        }
        let result = try await checkpoint(store, binding: binding, kind: .steps, previousAnchor: nil,
            batch: HealthChangeBatch(added: samples, deleted: [], anchor: Data([1]), hasMore: false), snapshots: snapshots)
        let rows = try await db.writer.read { try Row.fetchAll($0, sql: "SELECT value, excluded FROM metric_sample ORDER BY measured_at") }
        let owned = try await db.writer.read { try String.fetchAll($0, sql: "SELECT metric_id FROM hk_projection_state") }
        XCTAssertEqual(rows.map { $0["value"] as Double }, [6000, 200])
        XCTAssertEqual(rows.map { $0["excluded"] as Int }, [1, 0])
        XCTAssertEqual(result.preservedRows, 1)
        XCTAssertEqual(result.persistedRows, 1)
        XCTAssertFalse(result.hasMore)
        XCTAssertEqual(owned.count, 1)
        XCTAssertFalse(owned.contains(restoredID.uuidString))
    }

    func test_nonContributingSampleCannotClaimRestoredHeartOrSleepAggregate() async throws {
        for kind in [HealthDataKind.heartRate, .sleep] {
            let (db, store, patient) = try await makeStore()
            let binding = try await store.connect(timeZoneID: "UTC")
            let start = Date(timeIntervalSince1970: 1_700_006_400 + (kind == .sleep ? 43200 : 0))
            let window = HealthImportWindow(kind: kind, start: start, end: start.addingTimeInterval(kind == .sleep ? 86400 : 3600))
            let ref = window.prefix + (kind == .sleep ? "sleep_total" : "watch")
            try await db.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, excluded,
                      source_ref, measured_at, created_at) VALUES (?, ?, ?, 8, ?, 'device', 1, 0, ?, ?, 0)
                    """, arguments: [UUID().uuidString, patient.uuidString, kind == .sleep ? "sleep_total" : "heartRate",
                                      kind == .sleep ? "h" : "bpm", ref, start.timeIntervalSince1970])
            }
            // A lone heart-rate point or an inBed-only sleep sample produces no aggregate.
            let sample = HealthSampleReference(id: UUID(), kind: kind, sourceID: "watch",
                start: start.addingTimeInterval(60), end: start.addingTimeInterval(120))
            _ = try await checkpoint(store, binding: binding, kind: kind, previousAnchor: nil,
                batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
                snapshots: [HealthWindowSnapshot(window: window, samples: [sample], rows: [])])
            let result = try await checkpoint(store, binding: binding, kind: kind, previousAnchor: Data([1]),
                batch: HealthChangeBatch(added: [], deleted: [sample.id], anchor: Data([2]), hasMore: false),
                snapshots: [HealthWindowSnapshot(window: window, samples: [], rows: [])])
            let values = try await db.writer.read { try Double.fetchAll($0, sql: "SELECT value FROM metric_sample") }
            let owned = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hk_projection_state") }
            XCTAssertEqual(values, [8])
            XCTAssertEqual(owned, 0)
            XCTAssertEqual(result.preservedRows, 1)
            XCTAssertFalse(result.hasMore)
        }
    }

    func test_additionMustBeVisibleInEveryCoveringWindow() async throws {
        let (_, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let first = HealthImportWindow(kind: .heartRate, start: start, end: start.addingTimeInterval(3600))
        let second = HealthImportWindow(kind: .heartRate, start: first.end, end: start.addingTimeInterval(7200))
        let sample = HealthSampleReference(id: UUID(), kind: .heartRate, sourceID: "watch", start: start, end: first.end)
        let result = try await checkpoint(store, binding: binding, kind: .heartRate, previousAnchor: nil,
            batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: first, samples: [sample], rows: []),
                        HealthWindowSnapshot(window: second, samples: [], rows: [])])
        let anchor = try await store.anchor(binding: binding, kind: .heartRate)
        XCTAssertNil(anchor, "Seeing the UUID in an earlier window does not validate the later read")
        XCTAssertEqual(result.deferredWindows, 1)
        XCTAssertTrue(result.hasMore)
    }

    func test_invalidReferencesCannotBeStagedAndCorruptIndexIsNotInvented() async throws {
        let (db, store, patient) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        for bad in [Double.nan, .infinity, -.infinity, 1e30] {
            let sample = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch",
                start: start, end: Date(timeIntervalSince1970: bad))
            do {
                _ = try await store.stage(binding: binding, kind: .bloodOxygen, previousAnchor: nil,
                    page: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false))
                XCTFail("Invalid time references must fail before serialization or window expansion")
            } catch HealthImportStore.ImportError.invalidValue { }
        }
        try await db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO hk_sample_index (sample_id, type_key, patient_id, source_id, start_at, end_at)
                VALUES ('not-a-uuid', 'bloodOxygen', ?, 'watch', ?, ?)
                """, arguments: [patient.uuidString, start.timeIntervalSince1970, start.timeIntervalSince1970])
        }
        let sample = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch", start: start, end: start)
        let window = HealthImportWindow(kind: .bloodOxygen, start: start, end: start.addingTimeInterval(86400))
        do {
            _ = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: nil,
                batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
                snapshots: [HealthWindowSnapshot(window: window, samples: [sample], rows: [])])
            XCTFail("A corrupt stored sample UUID must not be replaced with a random UUID")
        } catch HealthImportStore.ImportError.invalidValue { }
        let anchor = try await store.anchor(binding: binding, kind: .bloodOxygen)
        XCTAssertNil(anchor)
    }

    func test_bindingDeletionCascadesMetadataButPreservesMetricFacts() async throws {
        let (db, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .bloodOxygen, start: start, end: start.addingTimeInterval(86400))
        let sample = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch", start: start, end: start)
        let row = DeviceMetricRow(metricKey: "blood_oxygen", value: 98, unit: "%", measuredAt: start,
            sourceRef: HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: sample.id, ordinal: nil))
        _ = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: nil,
            batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [sample], rows: [row])])
        _ = try await store.stage(binding: binding, kind: .bloodOxygen, previousAnchor: Data([1]),
            page: HealthChangeBatch(added: [], deleted: [sample.id], anchor: Data([2]), hasMore: false))
        try await db.writer.write { try $0.execute(sql: "DELETE FROM hk_import_binding") }
        let counts = try await db.writer.read { db in
            try ["hk_pending_batch", "hk_projection_state", "metric_sample"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        XCTAssertEqual(counts, [0, 0, 1])
    }

    func test_laterTombstoneReopensPreviouslyCompletedCoveringWindow() async throws {
        let (db, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let first = HealthImportWindow(kind: .heartRate, start: start, end: start.addingTimeInterval(3600))
        let second = HealthImportWindow(kind: .heartRate, start: first.end, end: start.addingTimeInterval(7200))
        let sample = HealthSampleReference(id: UUID(), kind: .heartRate, sourceID: "watch",
            start: start.addingTimeInterval(60), end: start.addingTimeInterval(3660))
        let initial = try await store.stage(binding: binding, kind: .heartRate, previousAnchor: nil,
            page: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false))
        let row = DeviceMetricRow(metricKey: "heart_rate", value: 80, unit: "bpm", sampleCount: 3,
            measuredAt: start, sourceRef: first.prefix + "watch", sourceIdentifier: "watch")
        _ = try await store.commit(binding: binding, kind: .heartRate, pending: initial,
            snapshots: [HealthWindowSnapshot(window: first, samples: [sample], rows: [row])])
        let extended = try await store.stage(binding: binding, kind: .heartRate, previousAnchor: Data([1]),
            page: HealthChangeBatch(added: [], deleted: [sample.id], anchor: Data([2]), hasMore: false))
        let partial = try await store.commit(binding: binding, kind: .heartRate, pending: extended,
            snapshots: [HealthWindowSnapshot(window: second, samples: [], rows: [])])
        let interimAnchor = try await store.anchor(binding: binding, kind: .heartRate)
        XCTAssertTrue(partial.hasMore)
        XCTAssertNil(interimAnchor, "The earlier projection also needs the newly staged tombstone")
        let loaded = try await store.pendingBatch(binding: binding, kind: .heartRate)
        let resumed = try XCTUnwrap(loaded)
        _ = try await store.commit(binding: binding, kind: .heartRate, pending: resumed,
            snapshots: [HealthWindowSnapshot(window: first, samples: [], rows: [])])
        let rows = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        let anchor = try await store.anchor(binding: binding, kind: .heartRate)
        XCTAssertEqual(rows, 0)
        XCTAssertEqual(anchor, Data([2]))
    }

    func test_legacyAggregateCannotBeAdoptedByTimestampAndSourceName() async throws {
        let (db, store, patient) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .heartRate, start: start, end: start.addingTimeInterval(3600))
        try await db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, excluded,
                  source_name, measured_at, created_at) VALUES (?, ?, 'heartRate', 72, 'bpm', 'device', 1, 1, 'Watch', ?, 0)
                """, arguments: [UUID().uuidString, patient.uuidString, start.timeIntervalSince1970])
        }
        let sample = HealthSampleReference(id: UUID(), kind: .heartRate, sourceID: "watch", start: start, end: start.addingTimeInterval(60))
        let row = DeviceMetricRow(metricKey: "heart_rate", value: 84, unit: "bpm", sampleCount: 3,
            sourceName: "Watch", measuredAt: start, sourceRef: window.prefix + "watch", sourceIdentifier: "watch")
        let result = try await checkpoint(store, binding: binding, kind: .heartRate, previousAnchor: nil,
            batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [sample], rows: [row])])
        let rows = try await db.writer.read { try Row.fetchAll($0, sql: "SELECT value, excluded, source_ref FROM metric_sample") }
        let owned = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hk_projection_state") }
        XCTAssertEqual(rows.count, 1)
        let saved = try XCTUnwrap(rows.first)
        XCTAssertEqual(saved["value"] as Double, 72)
        XCTAssertEqual(saved["excluded"] as Int, 1)
        XCTAssertNil(saved["source_ref"] as String?)
        XCTAssertEqual(owned, 0)
        XCTAssertEqual(result.preservedRows, 1)
    }

    func test_visibleReferenceWithoutItsPriorRowDoesNotAuthorizeDeletion() async throws {
        let (db, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .bloodOxygen, start: start, end: start.addingTimeInterval(86400))
        let original = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch", start: start, end: start)
        let added = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch",
            start: start.addingTimeInterval(60), end: start.addingTimeInterval(60))
        let oldRow = DeviceMetricRow(metricKey: "blood_oxygen", value: 98, unit: "%", measuredAt: original.end,
            sourceRef: HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: original.id, ordinal: nil))
        let newRow = DeviceMetricRow(metricKey: "blood_oxygen", value: 97, unit: "%", measuredAt: added.end,
            sourceRef: HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: added.id, ordinal: nil))
        _ = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: nil,
            batch: HealthChangeBatch(added: [original], deleted: [], anchor: Data([1]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [original], rows: [oldRow])])
        let result = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: Data([1]),
            batch: HealthChangeBatch(added: [added], deleted: [], anchor: Data([2]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [original, added], rows: [newRow])])
        let values = try await db.writer.read { try Double.fetchAll($0, sql: "SELECT value FROM metric_sample") }
        let anchor = try await store.anchor(binding: binding, kind: .bloodOxygen)
        XCTAssertEqual(values, [98])
        XCTAssertEqual(result.deferredWindows, 1)
        XCTAssertEqual(anchor, Data([1]))
    }

    func test_stalePendingRevisionCannotCommitOverAStagedSuccessor() async throws {
        let (_, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let first = try await store.stage(binding: binding, kind: .heartRate, previousAnchor: nil,
            page: HealthChangeBatch(added: [], deleted: [], anchor: Data([1]), hasMore: false))
        _ = try await store.stage(binding: binding, kind: .heartRate, previousAnchor: Data([1]),
            page: HealthChangeBatch(added: [], deleted: [], anchor: Data([2]), hasMore: false))
        do {
            _ = try await store.commit(binding: binding, kind: .heartRate, pending: first, snapshots: [])
            XCTFail("An old materializer cannot discard a newer durable page")
        } catch HealthImportStore.ImportError.staleAnchor { }
        let anchor = try await store.anchor(binding: binding, kind: .heartRate)
        let latest = try await store.pendingBatch(binding: binding, kind: .heartRate)
        XCTAssertNil(anchor)
        XCTAssertEqual(latest?.batch.anchor, Data([2]))
    }

    func test_subsecondReplayUsesThePersistedEpochPrecision() async throws {
        let (db, store, _) = try await makeStore()
        let binding = try await store.connect(timeZoneID: "UTC")
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let precise = Date(timeIntervalSinceReferenceDate: 721_699_200 + 0.0000001)
        let window = HealthImportWindow(kind: .bloodOxygen, start: start, end: start.addingTimeInterval(86400))
        let a = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch", start: precise, end: precise)
        let b = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch",
            start: start.addingTimeInterval(60), end: start.addingTimeInterval(60))
        let rows = [a, b].map {
            DeviceMetricRow(metricKey: "blood_oxygen", value: 98, unit: "%", measuredAt: $0.end,
                sourceRef: HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: $0.id, ordinal: nil))
        }
        _ = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: nil,
            batch: HealthChangeBatch(added: [a], deleted: [], anchor: Data([1]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [a], rows: [rows[0]])])
        let result = try await checkpoint(store, binding: binding, kind: .bloodOxygen, previousAnchor: Data([1]),
            batch: HealthChangeBatch(added: [b], deleted: [], anchor: Data([2]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [a, b], rows: rows)])
        let count = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        XCTAssertEqual(count, 2)
        XCTAssertFalse(result.hasMore, "A Unix/reference-epoch round trip must not look like a changed sample UUID")
    }
}
