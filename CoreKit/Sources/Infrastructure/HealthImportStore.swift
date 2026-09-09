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

    /// Fetch progress is durable but is not a materialization checkpoint.
    public struct PendingBatch: Sendable, Equatable, Codable {
        public let previousAnchor: Data?
        public let batch: HealthChangeBatch
        public let completedWindows: Set<HealthImportWindow>
        public let reconcileAfter: Date?
        public let revision: UUID
    }

    public struct CommitReport: Sendable, Equatable {
        public var persistedRows = 0
        public var preservedRows = 0
        public var deferredWindows = 0
        public var hasMore = false
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

    public func pendingBatch(binding: Binding, kind: HealthDataKind) async throws -> PendingBatch? {
        try await writer.read { db in
            try Self.requireBinding(binding, db: db)
            return try Self.pending(binding: binding, kind: kind, db: db)
        }
    }

    /// Append one bounded page. Missing identities never prevent fetching its successor.
    public func stage(binding: Binding, kind: HealthDataKind, previousAnchor: Data?,
                      page: HealthChangeBatch) async throws -> PendingBatch {
        try Task.checkCancellation()
        return try await writer.write { db in
            try Task.checkCancellation()
            try Self.requireEnabled(db)
            try Self.requireBinding(binding, db: db)
            guard page.added.count <= 500, page.deleted.count <= 500,
                  page.added.count + page.deleted.count <= 500, !page.anchor.isEmpty,
                  !page.hasMore || !page.added.isEmpty || !page.deleted.isEmpty else { throw ImportError.invalidValue }
            let committed = try Self.anchor(db, key: Self.anchorKey(binding, kind))
            let prior = try Self.pending(binding: binding, kind: kind, db: db)
            guard (prior?.batch.anchor ?? committed) == previousAnchor,
                  prior == nil || prior?.previousAnchor == committed else { throw ImportError.staleAnchor }
            if page.hasMore || !page.added.isEmpty || !page.deleted.isEmpty {
                guard page.anchor != previousAnchor else { throw ImportError.staleAnchor }
            }
            var added = try Self.validatedReferences(prior?.batch.added ?? [], kind: kind, calendar: binding.calendar)
            let incoming = try Self.validatedReferences(page.added, kind: kind, calendar: binding.calendar)
            for (id, ref) in incoming {
                if let old = added[id], old != ref { throw ImportError.invalidValue }
                added[id] = ref
            }
            let pageDeletions = Set(page.deleted)
            let deleted = Set(prior?.batch.deleted ?? []).union(pageDeletions)
            let oldReferences = try Self.deletedReferences(page.deleted, binding: binding, kind: kind, db: db)
            let touched = Set((page.added + oldReferences + added.values.filter { pageDeletions.contains($0.id) })
                .flatMap { HealthImportWindow.covering($0, calendar: binding.calendar) })
            let pending = PendingBatch(previousAnchor: committed,
                batch: HealthChangeBatch(added: added.values.sorted { $0.id.uuidString < $1.id.uuidString },
                    deleted: deleted.sorted { $0.uuidString < $1.uuidString }, anchor: page.anchor, hasMore: page.hasMore),
                completedWindows: (prior?.completedWindows ?? []).subtracting(touched),
                reconcileAfter: prior?.reconcileAfter, revision: UUID())
            try Self.savePending(pending, binding: binding, kind: kind, db: db)
            return pending
        }
    }

    public func affectedWindows(binding: Binding, kind: HealthDataKind,
                                batch: HealthChangeBatch) async throws -> [HealthImportWindow] {
        let deleted = try await writer.read { db in
            try Self.requireBinding(binding, db: db)
            return try Self.deletedReferences(batch.deleted, binding: binding, kind: kind, db: db)
        }
        _ = try Self.validatedReferences(batch.added, kind: kind, calendar: binding.calendar)
        return Set((batch.added + deleted).flatMap {
            HealthImportWindow.covering($0, calendar: binding.calendar)
        }).sorted { $0.start < $1.start }
    }

    /// Complete windows can progress independently; the committed cursor waits for the entire drained batch.
    public func commit(binding: Binding, kind: HealthDataKind, pending: PendingBatch,
                       snapshots: [HealthWindowSnapshot],
                       attemptedWindows: [HealthImportWindow]? = nil) async throws -> CommitReport {
        try Task.checkCancellation()
        return try await writer.write { db in
            try Task.checkCancellation()
            try Self.requireEnabled(db)
            try Self.requireBinding(binding, db: db)
            let key = Self.anchorKey(binding, kind)
            guard try Self.anchor(db, key: key) == pending.previousAnchor,
                  try Self.pending(binding: binding, kind: kind, db: db) == pending else { throw ImportError.staleAnchor }
            let batch = pending.batch
            guard !batch.hasMore else { throw ImportError.incompleteSnapshot }
            _ = try Self.validatedReferences(batch.added, kind: kind, calendar: binding.calendar)
            let tombstones = Set(batch.deleted)
            let deleted = try Self.deletedReferences(batch.deleted, binding: binding, kind: kind, db: db)
            let requiredWindows = Set((batch.added + deleted).flatMap { HealthImportWindow.covering($0, calendar: binding.calendar) })
            let remaining = requiredWindows.subtracting(pending.completedWindows)
            let supplied = Set(snapshots.map(\.window))
            let attempted = attemptedWindows ?? snapshots.map(\.window)
            let requested = Set(attempted)
            guard pending.completedWindows.isSubset(of: requiredWindows), supplied.count == snapshots.count,
                  requested.count == attempted.count, requested.isSubset(of: remaining), supplied.isSubset(of: requested),
                  !attempted.isEmpty || remaining.isEmpty else {
                throw ImportError.incompleteSnapshot
            }

            // Capture actual references before any window writes. One series can own several windows.
            var knownByWindow: [HealthImportWindow: [HealthSampleReference]] = [:]
            for snapshot in snapshots {
                guard snapshot.window.kind == kind, snapshot.window.isValid else { throw ImportError.invalidValue }
                knownByWindow[snapshot.window] = try Row.fetchAll(db, sql: """
                    SELECT * FROM hk_sample_index WHERE patient_id = ? AND type_key = ?
                      AND end_at >= ? AND start_at < ?
                    """, arguments: [binding.patientId.uuidString, kind.rawValue,
                                      snapshot.window.start.timeIntervalSince1970,
                                      snapshot.window.end.timeIntervalSince1970])
                    .map { try Self.decodeReference($0, kind: kind) }
            }

            var report = CommitReport()
            report.deferredWindows = requested.subtracting(supplied).count
            var completed = pending.completedWindows
            var preserved = Set<String>()
            var readings: [MetricReading] = []
            for snapshot in snapshots {
                let window = snapshot.window
                let known = knownByWindow[window] ?? []
                let visible = try Self.validatedReferences(snapshot.samples, kind: kind, calendar: binding.calendar)
                guard snapshot.samples.allSatisfy({ window.overlaps($0) }), snapshot.rejected >= 0 else { throw ImportError.invalidValue }
                let kept = Set(snapshot.rows.compactMap(\.sourceRef))
                guard kept.count == snapshot.rows.count else { throw ImportError.invalidValue }
                let rowsByIdentity = Dictionary(uniqueKeysWithValues: snapshot.rows.compactMap { row in
                    row.sourceRef.map { ($0, row) }
                })
                for row in snapshot.rows {
                    try Self.validateRow(row, window: window, visible: visible)
                }
                for reading in snapshot.readings {
                    guard reading.origin == .device, let identity = reading.sampleID,
                          let row = rowsByIdentity[identity], row.value == reading.value, row.unit == reading.unit,
                          row.metricKey == reading.metricKey, row.measuredAt == reading.measuredAt,
                          row.sourceIdentifier == reading.sourceIdentifier else { throw ImportError.invalidValue }
                }

                var arguments: [DatabaseValueConvertible] = [binding.id.uuidString, binding.patientId.uuidString,
                                                            window.identityPrefix + "%"]
                if !kind.isAggregated {
                    arguments.append(window.start.timeIntervalSince1970)
                    arguments.append(window.end.timeIntervalSince1970)
                }
                let prior = try Row.fetchAll(db, sql: """
                    SELECT m.id, m.source_ref, EXISTS(
                      SELECT 1 FROM hk_projection_state p WHERE p.binding_id = ? AND p.metric_id = m.id) AS owned
                    FROM metric_sample m WHERE m.patient_id = ? AND m.origin = 'device' AND m.source_ref LIKE ?
                    \(kind.isAggregated ? "" : "AND m.measured_at >= ? AND m.measured_at < ?")
                    ORDER BY owned DESC, m.id
                    """, arguments: StatementArguments(arguments))
                let priorByIdentity = Dictionary(grouping: prior) { $0["source_ref"] as String }
                var complete = Set(visible.keys).isDisjoint(with: tombstones)
                for ref in known + batch.added.filter({ window.overlaps($0) }) where !tombstones.contains(ref.id) {
                    if let seen = visible[ref.id] {
                        // The index stores Unix-epoch Doubles; comparing reference-epoch Dates can add rounding noise.
                        guard seen.sourceID == ref.sourceID,
                              seen.start.timeIntervalSince1970 == ref.start.timeIntervalSince1970,
                              seen.end.timeIntervalSince1970 == ref.end.timeIntervalSince1970 else { throw ImportError.invalidValue }
                    } else { complete = false }
                }
                let deletedHere = known.filter {
                    tombstones.contains($0.id) && HealthImportWindow.covering($0, calendar: binding.calendar).contains(window)
                }
                let deletedIDs = Set(deletedHere.map(\.id))
                let deletedSources = Set(deletedHere.map(\.sourceID))
                let removable = Set(prior.compactMap { row -> String? in
                    let identity: String = row["source_ref"]
                    guard (row["owned"] as Int) == 1, !kept.contains(identity) else { return nil }
                    switch kind {
                    case .heartRate:
                        guard deletedSources.contains(String(identity.dropFirst(window.prefix.count))) else { return nil }
                    case .steps, .sleep:
                        guard !deletedIDs.isEmpty else { return nil }
                    case .restingHeartRate, .bloodOxygen, .respiratoryRate:
                        guard let id = HealthImportWindow.sampleID(fromIdentity: identity, kind: kind),
                              deletedIDs.contains(id) else { return nil }
                    }
                    return row["id"] as String
                })
                // A missing row is not a deletion either, even if its parent UUID was visible.
                for row in prior where (row["owned"] as Int) == 1 {
                    if !kept.contains(row["source_ref"] as String), !removable.contains(row["id"] as String) { complete = false }
                }
                guard complete else { report.deferredWindows += 1; continue }

                for row in prior {
                    let id: String = row["id"]
                    guard UUID(uuidString: id) != nil else { throw ImportError.invalidValue }
                    if removable.contains(id) {
                        try db.execute(sql: "DELETE FROM metric_sample WHERE id = ?", arguments: [id])
                        report.persistedRows += db.changesCount
                    } else if (row["owned"] as Int) == 0, kind.isAggregated || !kept.contains(row["source_ref"] as String) {
                        preserved.insert(id)
                    }
                }
                for row in snapshot.rows {
                    guard let identity = row.sourceRef else { throw ImportError.invalidValue }
                    let matches = priorByIdentity[identity] ?? []
                    if kind.isAggregated {
                        // Legacy NULL identities must not be adopted by a matching timestamp/name either.
                        let legacy = try String.fetchAll(db, sql: """
                            SELECT id FROM metric_sample WHERE patient_id = ? AND origin = 'device' AND source_ref IS NULL
                              AND metric_key = ? AND measured_at = ? AND unit = ? AND source_name IS ?
                            """, arguments: [binding.patientId.uuidString, MetricType(grammarKey: row.metricKey)?.rawValue ?? row.metricKey,
                                             row.measuredAt.timeIntervalSince1970, row.unit, row.sourceName])
                        let unowned = matches.filter { ($0["owned"] as Int) == 0 }.map { $0["id"] as String } + legacy
                        if !unowned.isEmpty {
                            preserved.formUnion(unowned)
                            // 审查修复：同身份同时存在「备份恢复的非自有行」与
                            // 「投影态自有行」时，旧实现 preserve 后 continue——
                            // 自有行永不再刷新（窗口已判完成、锚点推进，后续
                            // 轮次仍走同一跳过分支），恢复前的陈旧值永久留存。
                            // 恢复行保留（防回退）的同时刷新自有行。
                            guard matches.contains(where: { ($0["owned"] as Int) == 1 }) else { continue }
                        }
                    }
                    let id = (matches.first { ($0["owned"] as Int) == 1 }.map { $0["id"] as String })
                        ?? (matches.first.map { $0["id"] as String }) ?? UUID().uuidString
                    guard UUID(uuidString: id) != nil else { throw ImportError.invalidValue }
                    report.persistedRows += try Self.writeProjection(row, id: id, patientId: binding.patientId, db: db)
                    try db.execute(sql: """
                        INSERT INTO hk_projection_state (binding_id, metric_id) VALUES (?, ?)
                        ON CONFLICT(binding_id, metric_id) DO NOTHING
                        """, arguments: [binding.id.uuidString, id])
                }
                for ref in snapshot.samples {
                    try db.execute(sql: """
                        INSERT INTO hk_sample_index (sample_id, type_key, patient_id, source_id, start_at, end_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(sample_id, type_key, patient_id) DO UPDATE SET
                          source_id = excluded.source_id, start_at = excluded.start_at, end_at = excluded.end_at
                        """, arguments: [ref.id.uuidString, kind.rawValue, binding.patientId.uuidString,
                                          ref.sourceID, ref.start.timeIntervalSince1970, ref.end.timeIntervalSince1970])
                }
                readings.append(contentsOf: snapshot.readings)
                completed.insert(window)
            }
            _ = try GuidelineStore.recordQualifiedHealthReadings(readings, patientId: binding.patientId, db: db)
            report.preservedRows = preserved.count
            report.hasMore = completed != requiredWindows
            if report.hasMore {
                try Self.savePending(PendingBatch(previousAnchor: pending.previousAnchor, batch: batch,
                    completedWindows: completed, reconcileAfter: attempted.last?.start ?? pending.reconcileAfter,
                    revision: UUID()), binding: binding, kind: kind, db: db)
                return report
            }
            // Retire tombstoned references only when every dependent window has been reconciled.
            for id in batch.deleted {
                try db.execute(sql: "DELETE FROM hk_sample_index WHERE sample_id = ? AND type_key = ? AND patient_id = ?",
                               arguments: [id.uuidString, kind.rawValue, binding.patientId.uuidString])
            }
            try db.execute(sql: """
                INSERT INTO hk_sync_anchor (anchor_key, anchor_value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(anchor_key) DO UPDATE SET anchor_value = excluded.anchor_value, updated_at = excluded.updated_at
                """, arguments: [key, batch.anchor.base64EncodedString(), Date().timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM hk_pending_batch WHERE binding_id = ? AND type_key = ?",
                           arguments: [binding.id.uuidString, kind.rawValue])
            return report
        }
    }

    private static func deletedReferences(_ ids: [UUID], binding: Binding, kind: HealthDataKind,
                                           db: Database) throws -> [HealthSampleReference] {
        var references: [HealthSampleReference] = []
        for offset in stride(from: 0, to: ids.count, by: 500) {
            let page = ids[offset..<min(offset + 500, ids.count)].map(\.uuidString)
            let placeholders = Array(repeating: "?", count: page.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM hk_sample_index WHERE type_key = ? AND patient_id = ? AND sample_id IN (\(placeholders))
                """, arguments: StatementArguments([kind.rawValue, binding.patientId.uuidString] + page))
            references.append(contentsOf: try rows.map { try decodeReference($0, kind: kind) })
        }
        return references
    }

    private static func decodeReference(_ row: Row, kind: HealthDataKind) throws -> HealthSampleReference {
        guard let id = UUID(uuidString: row["sample_id"] as String),
              (row["type_key"] as String) == kind.rawValue else { throw ImportError.invalidValue }
        let ref = HealthSampleReference(id: id, kind: kind, sourceID: row["source_id"],
            start: Date(timeIntervalSince1970: row["start_at"]), end: Date(timeIntervalSince1970: row["end_at"]))
        guard ref.isValid else { throw ImportError.invalidValue }
        return ref
    }

    private static func validatedReferences(_ references: [HealthSampleReference], kind: HealthDataKind,
                                             calendar: Calendar) throws -> [UUID: HealthSampleReference] {
        var result: [UUID: HealthSampleReference] = [:]
        for ref in references {
            guard ref.kind == kind, ref.isValid, !HealthImportWindow.covering(ref, calendar: calendar).isEmpty else {
                throw ImportError.invalidValue
            }
            if let prior = result[ref.id], prior != ref { throw ImportError.invalidValue }
            result[ref.id] = ref
        }
        return result
    }

    private static func pending(binding: Binding, kind: HealthDataKind, db: Database) throws -> PendingBatch? {
        guard let json = try String.fetchOne(db, sql: "SELECT payload_json FROM hk_pending_batch WHERE binding_id = ? AND type_key = ?",
                                            arguments: [binding.id.uuidString, kind.rawValue]) else { return nil }
        let pending = try JSONDecoder().decode(PendingBatch.self, from: Data(json.utf8))
        guard !pending.batch.anchor.isEmpty, pending.reconcileAfter?.timeIntervalSince1970.isFinite != false,
              pending.completedWindows.allSatisfy({ $0.kind == kind && $0.isValid }) else { throw ImportError.invalidValue }
        _ = try validatedReferences(pending.batch.added, kind: kind, calendar: binding.calendar)
        return pending
    }

    private static func savePending(_ pending: PendingBatch, binding: Binding, kind: HealthDataKind, db: Database) throws {
        let json = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO hk_pending_batch (binding_id, type_key, payload_json) VALUES (?, ?, ?)
            ON CONFLICT(binding_id, type_key) DO UPDATE SET payload_json = excluded.payload_json
            """, arguments: [binding.id.uuidString, kind.rawValue, json])
    }

    private static func validateRow(_ row: DeviceMetricRow, window: HealthImportWindow,
                                    visible: [UUID: HealthSampleReference]) throws {
        guard let identity = row.sourceRef, window.contains(sourceRef: identity, measuredAt: row.measuredAt),
              row.value.isFinite, row.valueMin?.isFinite != false, row.valueMax?.isFinite != false,
              row.windowEnd?.timeIntervalSince1970.isFinite != false, row.sampleCount.map({ $0 >= 0 }) != false,
              !row.unit.isEmpty else { throw ImportError.invalidValue }
        let key = MetricType(grammarKey: row.metricKey)?.rawValue ?? row.metricKey
        let allowed: Set<String>
        switch window.kind {
        case .heartRate: allowed = ["heartRate"]
        case .restingHeartRate: allowed = ["restingHeartRate"]
        case .bloodOxygen: allowed = ["bloodOxygen"]
        case .respiratoryRate: allowed = ["respiratory_rate"]
        case .steps: allowed = ["steps"]
        case .sleep: allowed = ["sleep_total", "sleep_deep", "sleep_rem", "sleep_awake", "sleep_core", "sleep_unspecified"]
        }
        guard allowed.contains(key) else { throw ImportError.invalidValue }
        if !window.kind.isAggregated {
            guard let id = HealthImportWindow.sampleID(fromIdentity: identity, kind: window.kind),
                  let ref = visible[id], row.measuredAt >= ref.start, row.measuredAt <= ref.end,
                  row.sourceIdentifier == nil || row.sourceIdentifier == ref.sourceID else { throw ImportError.invalidValue }
        } else if window.kind == .heartRate {
            let source = String(identity.dropFirst(window.prefix.count))
            guard visible.values.contains(where: { $0.sourceID == source }),
                  row.sourceIdentifier == nil || row.sourceIdentifier == source else { throw ImportError.invalidValue }
        } else {
            guard identity == window.prefix + (window.kind == .steps ? "sum" : key), !visible.isEmpty else { throw ImportError.invalidValue }
        }
    }

    /// Identity-only writes: timestamp/source-name matching cannot prove a restored sample's provenance.
    private static func writeProjection(_ row: DeviceMetricRow, id: String, patientId: UUID, db: Database) throws -> Int {
        try db.execute(sql: """
            INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, excluded,
              value_min, value_max, sample_count, source_name, source_version, source_product, source_ref,
              source_identifier, aggregation_kind, window_end, measured_at, created_at)
            VALUES (?, ?, ?, ?, ?, 'device', 1, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET metric_key = excluded.metric_key, value = excluded.value, unit = excluded.unit,
              value_min = excluded.value_min, value_max = excluded.value_max, sample_count = excluded.sample_count,
              source_name = excluded.source_name, source_version = excluded.source_version, source_product = excluded.source_product,
              source_identifier = excluded.source_identifier, aggregation_kind = excluded.aggregation_kind,
              window_end = excluded.window_end, measured_at = excluded.measured_at
            WHERE metric_sample.metric_key IS NOT excluded.metric_key OR metric_sample.value IS NOT excluded.value
              OR metric_sample.unit IS NOT excluded.unit OR metric_sample.value_min IS NOT excluded.value_min
              OR metric_sample.value_max IS NOT excluded.value_max OR metric_sample.sample_count IS NOT excluded.sample_count
              OR metric_sample.source_name IS NOT excluded.source_name OR metric_sample.source_version IS NOT excluded.source_version
              OR metric_sample.source_product IS NOT excluded.source_product OR metric_sample.source_identifier IS NOT excluded.source_identifier
              OR metric_sample.aggregation_kind IS NOT excluded.aggregation_kind OR metric_sample.window_end IS NOT excluded.window_end
              OR metric_sample.measured_at IS NOT excluded.measured_at
            """, arguments: [id, patientId.uuidString, MetricType(grammarKey: row.metricKey)?.rawValue ?? row.metricKey,
                              row.value, row.unit, row.valueMin, row.valueMax, row.sampleCount, row.sourceName, row.sourceVersion,
                              row.sourceProduct, row.sourceRef, row.sourceIdentifier, row.aggregation?.rawValue,
                              row.windowEnd?.timeIntervalSince1970, row.measuredAt.timeIntervalSince1970, Date().timeIntervalSince1970])
        return db.changesCount
    }

    private static func requireBinding(_ binding: Binding, db: Database) throws {
        guard try Self.binding(db) == binding, try ownerPatient(db) == binding.patientId else { throw ImportError.bindingChanged }
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
        guard let id else { return nil }
        guard let patient = UUID(uuidString: id) else { throw ImportError.invalidValue }
        return patient
    }

    private static func requireEnabled(_ db: Database) throws {
        let value = try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?",
                                       arguments: [AppSettingKey.authHealthRead.rawValue])
        guard SettingsRules.resolved(value, key: .authHealthRead) == "true" else { throw ImportError.disabled }
    }
}
#endif
