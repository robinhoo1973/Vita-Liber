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
        _ = try await store.commit(binding: binding, kind: .bloodOxygen, previousAnchor: nil,
            batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [sample], rows: [row])])
        let deleted = HealthChangeBatch(added: [], deleted: [sample.id], anchor: Data([2]), hasMore: false)
        let windows = try await store.affectedWindows(binding: binding, kind: .bloodOxygen, batch: deleted)
        XCTAssertEqual(windows.count, 1)
        do {
            _ = try await store.commit(binding: binding, kind: .bloodOxygen, previousAnchor: Data([1]),
                batch: deleted, snapshots: [])
            XCTFail("A known deletion must reconcile its affected window before advancing")
        } catch HealthImportStore.ImportError.incompleteSnapshot { }
        _ = try await store.commit(binding: binding, kind: .bloodOxygen, previousAnchor: Data([1]),
            batch: deleted, snapshots: [HealthWindowSnapshot(window: window, samples: [], rows: [])])
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
        _ = try await store.commit(binding: binding, kind: .bloodOxygen, previousAnchor: nil,
            batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [sample], rows: [row])])
        do {
            _ = try await store.commit(binding: binding, kind: .bloodOxygen, previousAnchor: Data([1]),
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
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO app_settings (key, value) VALUES ('authHealthRead', 'false')")
        }
        do {
            _ = try await store.commit(binding: binding, kind: .heartRate, previousAnchor: nil,
                batch: HealthChangeBatch(added: [], deleted: [], anchor: Data([1]), hasMore: false), snapshots: [])
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
            _ = try await store.commit(binding: binding, kind: .heartRate, previousAnchor: nil,
                batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
                snapshots: [])
            XCTFail("A cursor must never acknowledge an unprocessed addition")
        } catch HealthImportStore.ImportError.incompleteSnapshot { }
        let anchor = try await store.anchor(binding: binding, kind: .heartRate)
        XCTAssertNil(anchor)
    }

    /// P1（二轮复审）：同窗口两条已索引样本被删除，但本页只带一条 tombstone——
    /// 快照为空是真实读取（该类型批次非空即证明可读）。旧实现按
    /// known⊄visible 拒绝并回滚游标，下一轮仍是同一页 → 永久卡死。
    func test_missingTombstoneOnLaterPageDoesNotStallTheCursor() async throws {
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
        _ = try await store.commit(binding: binding, kind: .bloodOxygen, previousAnchor: nil,
            batch: HealthChangeBatch(added: [a, b], deleted: [], anchor: Data([1]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [a, b], rows: rows)])
        // Page 1 carries only A's tombstone; HealthKit already shows neither sample.
        let page1 = HealthChangeBatch(added: [], deleted: [a.id], anchor: Data([2]), hasMore: true)
        _ = try await store.commit(binding: binding, kind: .bloodOxygen, previousAnchor: Data([1]),
            batch: page1, snapshots: [HealthWindowSnapshot(window: window, samples: [], rows: [])])
        let count = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }
        let index = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hk_sample_index") }
        XCTAssertEqual(count, 0, "Both readings are gone in HealthKit; the truthful read removes both projections")
        XCTAssertEqual(index, 0)
        XCTAssertEqual(try await store.anchor(binding: binding, kind: .bloodOxygen), Data([2]))
        // Page 2 finally delivers B's tombstone: nothing left to reconcile, cursor still advances.
        let page2 = HealthChangeBatch(added: [], deleted: [b.id], anchor: Data([3]), hasMore: false)
        XCTAssertTrue(try await store.affectedWindows(binding: binding, kind: .bloodOxygen, batch: page2).isEmpty)
        _ = try await store.commit(binding: binding, kind: .bloodOxygen, previousAnchor: Data([2]), batch: page2, snapshots: [])
        XCTAssertEqual(try await store.anchor(binding: binding, kind: .bloodOxygen), Data([3]))
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
        _ = try await store.commit(binding: binding, kind: .bloodOxygen, previousAnchor: nil,
            batch: HealthChangeBatch(added: [b], deleted: [], anchor: Data([1]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [b], rows: [bRow])])
        let values = try await db.writer.read { db in
            try Double.fetchAll(db, sql: "SELECT value FROM metric_sample ORDER BY measured_at")
        }
        XCTAssertEqual(values, [97, 99], "A (restored, unindexed) survives; B is replayed onto its existing row")
        // Once B is indexed by this connection, its later deletion is honoured while A still survives.
        _ = try await store.commit(binding: binding, kind: .bloodOxygen, previousAnchor: Data([1]),
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
        _ = try await store.commit(binding: binding, kind: .bloodOxygen, previousAnchor: nil,
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
        _ = try await store.commit(binding: binding, kind: .bloodOxygen, previousAnchor: Data([1]),
            batch: HealthChangeBatch(added: [other], deleted: [], anchor: Data([2]), hasMore: false),
            snapshots: [HealthWindowSnapshot(window: window, samples: [sample, other], rows: [row(97), otherRow])])
        let rows = try await db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT value, excluded FROM metric_sample ORDER BY measured_at")
        }
        XCTAssertEqual(rows.map { $0["value"] as Double }, [97, 98])
        XCTAssertEqual(rows.map { $0["excluded"] as Int }, [1, 0], "Replay updates facts but never resurrects an excluded point")
        XCTAssertEqual(try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metric_sample") }, 2)
    }

    /// 快照只允许覆盖本批次要求的窗口：未被任何增删触及的窗口没有「可读」证明。
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
            _ = try await store.commit(binding: binding, kind: .bloodOxygen, previousAnchor: nil,
                batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
                snapshots: [HealthWindowSnapshot(window: touched, samples: [sample], rows: [row]),
                            HealthWindowSnapshot(window: other, samples: [], rows: [])])
            XCTFail("A snapshot outside the batch's windows carries no proof of readability")
        } catch HealthImportStore.ImportError.incompleteSnapshot { }
        XCTAssertNil(try await store.anchor(binding: binding, kind: .bloodOxygen))
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
            _ = try await store.commit(binding: binding, kind: .bloodOxygen, previousAnchor: nil,
                batch: HealthChangeBatch(added: [sample], deleted: [], anchor: Data([1]), hasMore: false),
                snapshots: [HealthWindowSnapshot(window: window, samples: [sample], rows: [row])])
            XCTFail("The injected DB error must fail the transaction")
        } catch is DatabaseError { }
        let counts = try await db.writer.read { db in
            try ["metric_sample", "hk_sample_index", "hk_sync_anchor"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        XCTAssertEqual(counts, [0, 0, 0])
    }
}
