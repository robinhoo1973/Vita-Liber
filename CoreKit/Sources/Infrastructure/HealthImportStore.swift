#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

public actor HealthImportStore {
    public struct Binding: Sendable, Equatable {
        public let id: UUID
        public let patientId: UUID
        public let timeZoneID: String
        public var calendar: Calendar {
            var result = Calendar(identifier: .gregorian)
            result.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)!
            return result
        }
    }

    public enum ImportError: Error {
        case disabled, missingOwner, bindingChanged, staleAnchor, incompleteSnapshot, invalidValue
    }

    private let writer: any DatabaseWriter
    public init(writer: any DatabaseWriter) { self.writer = writer }

    public func connect(timeZoneID: String = TimeZone.current.identifier) async throws -> Binding {
        try await writer.write { db in
            guard TimeZone(identifier: timeZoneID) != nil else { throw ImportError.invalidValue }
            try Self.requireEnabled(db)
            guard let patient = try Self.ownerPatient(db) else { throw ImportError.missingOwner }
            if let binding = try Self.binding(db) {
                guard binding.patientId == patient else { throw ImportError.bindingChanged }
                return binding
            }
            let binding = Binding(id: UUID(), patientId: patient, timeZoneID: timeZoneID)
            try db.execute(sql: """
                INSERT INTO hk_import_binding (singleton, id, patient_id, time_zone, connected_at)
                VALUES (1, ?, ?, ?, ?)
                """, arguments: [binding.id.uuidString, patient.uuidString, timeZoneID, Date().timeIntervalSince1970])
            return binding
        }
    }

    public func connection() async throws -> Binding? {
        try await writer.read { db in
            guard let binding = try Self.binding(db), try Self.ownerPatient(db) == binding.patientId else { return nil }
            return binding
        }
    }

    public func isEnabled() async throws -> Bool {
        try await writer.read { db in
            let value = try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?",
                                           arguments: [AppSettingKey.authHealthRead.rawValue])
            return SettingsRules.resolved(value, key: .authHealthRead) == "true"
        }
    }

    public func anchor(binding: Binding, kind: HealthDataKind) async throws -> Data? {
        try await writer.read { db in try Self.anchor(db, key: Self.anchorKey(binding, kind)) }
    }

    public func affectedWindows(binding: Binding, kind: HealthDataKind,
                                batch: HealthChangeBatch) async throws -> [HealthImportWindow] {
        let deleted = try await writer.read { db in
            try Self.deletedReferences(batch.deleted, binding: binding, kind: kind, db: db)
        }
        return Set((batch.added + deleted).flatMap {
            HealthImportWindow.covering($0, calendar: binding.calendar)
        }).sorted { $0.start < $1.start }
    }

    /// The cursor acknowledges exactly this batch. No external await is allowed inside the transaction.
    public func commit(binding: Binding, kind: HealthDataKind, previousAnchor: Data?,
                       batch: HealthChangeBatch, snapshots: [HealthWindowSnapshot]) async throws -> Int {
        try Task.checkCancellation()
        return try await writer.write { db in
            try Task.checkCancellation()
            try Self.requireEnabled(db)
            guard try Self.binding(db) == binding, try Self.ownerPatient(db) == binding.patientId else {
                throw ImportError.bindingChanged
            }
            let key = Self.anchorKey(binding, kind)
            guard try Self.anchor(db, key: key) == previousAnchor else { throw ImportError.staleAnchor }
            let tombstones = Set(batch.deleted.map(\.uuidString))
            guard batch.added.allSatisfy({ $0.kind == kind && !HealthImportWindow.covering($0, calendar: binding.calendar).isEmpty }) else {
                throw ImportError.invalidValue
            }
            let addedIDs = Set(batch.added.map { $0.id.uuidString }).subtracting(tombstones)
            let visibleIDs = Set(snapshots.flatMap(\.samples).map { $0.id.uuidString })
            let deleted = try Self.deletedReferences(batch.deleted, binding: binding, kind: kind, db: db)
            let requiredWindows = Set((batch.added + deleted).flatMap { HealthImportWindow.covering($0, calendar: binding.calendar) })
            // Exactly the windows this batch touches: a non-empty change batch for this kind proves the type is
            // readable right now, so each required window's snapshot is a truthful read. A snapshot for any other
            // window carries no such proof and must not drive deletions.
            guard addedIDs.isSubset(of: visibleIDs), requiredWindows == Set(snapshots.map(\.window)) else {
                throw ImportError.incompleteSnapshot
            }
            var changed = 0
            for snapshot in snapshots {
                guard snapshot.window.kind == kind, snapshot.window.end > snapshot.window.start,
                      snapshot.samples.allSatisfy({ $0.kind == kind && $0.end >= $0.start }) else {
                    throw ImportError.invalidValue
                }
                // Same overlap semantics as HealthKit's default date predicate (end >= start AND start < end).
                let known = try Row.fetchAll(db, sql: """
                    SELECT sample_id, source_id FROM hk_sample_index WHERE patient_id = ? AND type_key = ?
                      AND end_at >= ? AND start_at < ?
                    """, arguments: [binding.patientId.uuidString, kind.rawValue,
                                     snapshot.window.start.timeIntervalSince1970,
                                     snapshot.window.end.timeIntervalSince1970])
                    .map { HealthSampleReference(id: UUID(uuidString: $0["sample_id"]) ?? UUID(), kind: kind,
                                                 sourceID: $0["source_id"], start: snapshot.window.start,
                                                 end: snapshot.window.end) }
                let visible = Set(snapshot.samples.map { $0.id.uuidString })
                let kept = Set(snapshot.rows.compactMap(\.sourceRef))
                guard snapshot.rows.allSatisfy({ row in
                    row.sourceRef.map { snapshot.window.contains(sourceRef: $0, measuredAt: row.measuredAt) } == true
                }) else {
                    throw ImportError.invalidValue
                }
                let prior: [Row]
                if kind.isAggregated {
                    prior = try Row.fetchAll(db, sql: """
                        SELECT id, source_ref FROM metric_sample WHERE patient_id = ? AND origin = 'device'
                          AND source_ref LIKE ?
                        """, arguments: [binding.patientId.uuidString, snapshot.window.prefix + "%"])
                } else {
                    prior = try Row.fetchAll(db, sql: """
                        SELECT id, source_ref FROM metric_sample WHERE patient_id = ? AND origin = 'device'
                          AND source_ref LIKE ? AND measured_at >= ? AND measured_at < ?
                        """, arguments: [binding.patientId.uuidString, snapshot.window.identityPrefix + "%",
                                         snapshot.window.start.timeIntervalSince1970,
                                         snapshot.window.end.timeIntervalSince1970])
                }
                // Only rows this connection can attribute to indexed samples may be removed. Restored
                // projections (index cleared on restore) survive until the live store replays their identity.
                for row in prior {
                    let ref: String = row["source_ref"]
                    guard !kept.contains(ref),
                          Self.isOwned(sourceRef: ref, window: snapshot.window, known: known) else { continue }
                    try db.execute(sql: "DELETE FROM metric_sample WHERE id = ?", arguments: [row["id"] as String])
                    changed += db.changesCount
                }
                changed += try TrendQueryStore.upsertDeviceRows(snapshot.rows, patientId: binding.patientId, db: db)
                for ref in snapshot.samples {
                    try db.execute(sql: """
                        INSERT INTO hk_sample_index (sample_id, type_key, patient_id, source_id, start_at, end_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(sample_id, type_key, patient_id) DO UPDATE SET
                          source_id = excluded.source_id, start_at = excluded.start_at, end_at = excluded.end_at
                        """, arguments: [ref.id.uuidString, kind.rawValue, binding.patientId.uuidString,
                                         ref.sourceID, ref.start.timeIntervalSince1970, ref.end.timeIntervalSince1970])
                }
                // Known samples absent from a truthful read are gone (their tombstone may sit on a later page).
                for gone in known where !visible.contains(gone.id.uuidString) {
                    try db.execute(sql: "DELETE FROM hk_sample_index WHERE sample_id = ? AND type_key = ? AND patient_id = ?",
                                   arguments: [gone.id.uuidString, kind.rawValue, binding.patientId.uuidString])
                }
            }
            for id in batch.deleted {
                try db.execute(sql: "DELETE FROM hk_sample_index WHERE sample_id = ? AND type_key = ? AND patient_id = ?",
                               arguments: [id.uuidString, kind.rawValue, binding.patientId.uuidString])
            }
            _ = try GuidelineStore.recordQualifiedHealthReadings(snapshots.flatMap(\.readings),
                                                                  patientId: binding.patientId, db: db)
            try db.execute(sql: """
                INSERT INTO hk_sync_anchor (anchor_key, anchor_value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(anchor_key) DO UPDATE SET anchor_value = excluded.anchor_value, updated_at = excluded.updated_at
                """, arguments: [key, batch.anchor.base64EncodedString(), Date().timeIntervalSince1970])
            return changed
        }
    }

    /// A projected row is "owned" by this connection when the sample index attributes it to samples this
    /// binding imported: discrete rows by their sample UUID, hourly heart-rate rows by their source
    /// identifier, day/night aggregates by any indexed sample in the window.
    static func isOwned(sourceRef: String, window: HealthImportWindow, known: [HealthSampleReference]) -> Bool {
        switch window.kind {
        case .heartRate:
            let source = String(sourceRef.dropFirst(window.prefix.count))
            return known.contains { $0.sourceID == source }
        case .steps, .sleep:
            return !known.isEmpty
        case .restingHeartRate, .bloodOxygen, .respiratoryRate:
            guard let id = HealthImportWindow.sampleID(fromIdentity: sourceRef, kind: window.kind) else { return false }
            return known.contains { $0.id == id }
        }
    }

    private static func deletedReferences(_ ids: [UUID], binding: Binding, kind: HealthDataKind,
                                          db: Database) throws -> [HealthSampleReference] {
        try ids.compactMap { id in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM hk_sample_index WHERE sample_id = ? AND type_key = ? AND patient_id = ?
                """, arguments: [id.uuidString, kind.rawValue, binding.patientId.uuidString]) else { return nil }
            return HealthSampleReference(id: id, kind: kind, sourceID: row["source_id"],
                start: Date(timeIntervalSince1970: row["start_at"]), end: Date(timeIntervalSince1970: row["end_at"]))
        }
    }

    private static func anchorKey(_ binding: Binding, _ kind: HealthDataKind) -> String {
        "hk.v2.\(binding.id.uuidString).\(kind.rawValue)"
    }

    private static func anchor(_ db: Database, key: String) throws -> Data? {
        guard let encoded = try String.fetchOne(db, sql: "SELECT anchor_value FROM hk_sync_anchor WHERE anchor_key = ?",
                                               arguments: [key]) else { return nil }
        guard let data = Data(base64Encoded: encoded) else { throw ImportError.staleAnchor }
        return data
    }

    private static func binding(_ db: Database) throws -> Binding? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM hk_import_binding WHERE singleton = 1") else { return nil }
        guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]),
              TimeZone(identifier: row["time_zone"] as String) != nil else {
            throw ImportError.bindingChanged
        }
        return Binding(id: id, patientId: patient, timeZoneID: row["time_zone"])
    }

    private static func ownerPatient(_ db: Database) throws -> UUID? {
        let id = try String.fetchOne(db, sql: """
            SELECT p.id FROM local_owner o JOIN patient_profile p ON p.id = o.self_patient_id
            WHERE p.deleted_at IS NULL LIMIT 1
            """)
        return id.flatMap(UUID.init(uuidString:))
    }

    private static func requireEnabled(_ db: Database) throws {
        let value = try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?",
                                       arguments: [AppSettingKey.authHealthRead.rawValue])
        guard SettingsRules.resolved(value, key: .authHealthRead) == "true" else { throw ImportError.disabled }
    }
}
#endif
