import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure

// binds: SU-M1c-EXPORT / SU-M15-TREND / SU-M2-F16 (FR13.5, FR7.9, FR16.2)
@MainActor
final class HealthBackupAcceptanceTests: XCTestCase {
    private func makeStore() async throws -> (store: GRDBStore, patient: UUID, member: UUID) {
        let store = try GRDBStore.inMemory()
        let patient = UUID()
        let member = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, 'Owner', 'self', 10, 20), (?, 'Family', 'other', 30, 40)
                """, arguments: [patient.uuidString, member.uuidString])
            try db.execute(sql: """
                INSERT INTO local_owner (id, display_name, self_patient_id, created_at)
                VALUES (?, 'Owner', ?, 10)
                """, arguments: [UUID().uuidString, patient.uuidString])
        }
        return (store, patient, member)
    }

    private func makeMetricStore() async throws -> (store: GRDBStore, patient: UUID, member: UUID) {
        let (store, patient, member) = try await makeStore()
        try await GRDBCodeIndex(writer: store.writer).loadBundledSeedsIfNeeded()
        let readings: [(key: String, value: Double, unit: String, min: Double?, max: Double?,
                        count: Int?, aggregation: String, end: Double)] = [
            ("heartRate", 72.5, "bpm", 60, 92, 12, "hourlyAverage", 1_700_010_000),
            ("restingHeartRate", 58, "bpm", nil, nil, 1, "sample", 1_700_006_400),
            ("bloodOxygen", 98, "%", nil, nil, 1, "sample", 1_700_006_400),
            ("respiratory_rate", 16, "count/min", nil, nil, 1, "sample", 1_700_006_400),
            ("steps", 4321, "count", nil, nil, 3, "dailySum", 1_700_092_800),
            ("sleep_total", 7.25, "h", nil, nil, nil, "sleepDuration", 1_700_092_800),
            ("sleep_deep", 1.5, "h", nil, nil, nil, "sleepDuration", 1_700_092_800),
            ("sleep_rem", 1.75, "h", nil, nil, nil, "sleepDuration", 1_700_092_800),
            ("sleep_core", 3, "h", nil, nil, nil, "sleepDuration", 1_700_092_800),
            ("sleep_awake", 0.25, "h", nil, nil, nil, "sleepDuration", 1_700_092_800),
            ("sleep_unspecified", 1, "h", nil, nil, nil, "sleepDuration", 1_700_092_800),
        ]
        try await store.writer.write { db in
            for reading in readings {
                let id = UUID()
                try db.execute(sql: """
                    INSERT INTO metric_sample
                      (id, patient_id, metric_key, value, unit, origin, self_measured, excluded,
                       source_ref, value_min, value_max, sample_count, source_name, source_version,
                       source_product, source_identifier, aggregation_kind, window_end, measured_at, created_at)
                    VALUES (?, ?, ?, ?, ?, 'device', 1, ?, ?, ?, ?, ?, 'Fixture Watch', '10.6',
                            'Watch6,4', 'com.example.fixture.watch', ?, ?, 1700006400, 1700010001)
                    """, arguments: [id.uuidString, patient.uuidString, reading.key, reading.value,
                        reading.unit, reading.key == "heartRate" ? 1 : 0,
                        "hk:\(reading.key):1700006400:\(id.uuidString)", reading.min, reading.max,
                        reading.count, reading.aggregation, reading.end])
            }
            try db.execute(sql: """
                INSERT INTO metric_sample
                  (id, patient_id, metric_key, value, secondary_value, unit, origin, self_measured,
                   excluded, raw_label, measured_at, created_at)
                VALUES (?, ?, 'bloodPressureSys', 128, 82, 'mmHg', 'manual', 1, 0, 'BP', 1700006520, 1700010100)
                """, arguments: [UUID().uuidString, member.uuidString])
            try db.execute(sql: """
                INSERT INTO metric_sample
                  (id, patient_id, metric_key, value, unit, origin, self_measured, excluded,
                   source_ref, ref_low, ref_high, ref_source_label, raw_label, code_concept_id,
                   measured_at, created_at)
                VALUES (?, ?, 'glucose', 5.4, 'mmol/L', 'hospital', 0, 0, 'report-a',
                        3.9, 6.1, 'Lab A', 'GLU', 'c-glu-molar', 1700006520, 1700010200),
                       (?, ?, 'glucose', 5.8, 'mmol/L', 'hospital', 0, 0, 'report-b',
                        4.1, 5.9, 'Lab B', 'Glucose (plasma)', 'c-glu-molar', 1700092920, 1700100200)
                """, arguments: [UUID().uuidString, member.uuidString, UUID().uuidString, member.uuidString])
        }
        return (store, patient, member)
    }

    func test_backupRoundTripsFullMetricsWithoutPortableHealthKitConnection() async throws {
        let (source, patient, member) = try await makeMetricStore()
        try await source.writer.write { db in
            try db.execute(sql: "INSERT INTO app_settings (key, value) VALUES ('authHealthRead', 'true')")
        }
        let binding = try await HealthImportStore(writer: source.writer).connect(timeZoneID: "UTC")
        try await source.writer.write { db in
            try db.execute(sql: """
                INSERT INTO hk_sync_anchor (anchor_key, anchor_value, updated_at) VALUES (?, 'AQID', 50)
                """, arguments: ["hk.v2.\(binding.id.uuidString).heartRate"])
            try db.execute(sql: """
                INSERT INTO hk_sample_index (sample_id, type_key, patient_id, source_id, start_at, end_at)
                VALUES (?, 'heartRate', ?, 'com.example.fixture.watch', 1700006400, 1700006460)
                """, arguments: [UUID().uuidString, patient.uuidString])
        }
        let before = try await source.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM metric_sample ORDER BY id")
        }
        XCTAssertEqual(before.count, 14)
        let package = try await BackupService(writer: source.writer).createBackup()
        XCTAssertTrue(package.data.starts(with: Data("VLBU1".utf8)))

        let destination = try GRDBStore.inMemory()
        // The app seeds the shared code dictionary separately; it is not patient backup data.
        try await GRDBCodeIndex(writer: destination.writer).loadBundledSeedsIfNeeded()
        let backup = BackupService(writer: destination.writer)
        let analysis = try await backup.analyzeConflicts(from: package.data)
        XCTAssertTrue(analysis.conflicts.isEmpty)
        let payload = try await ExportService(writer: destination.writer).encode(analysis.envelope)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        for key in ["hk_import_binding", "hk_sync_anchor", "hk_sample_index", "app_settings"] {
            XCTAssertNil(json[key], "Local authorization/checkpoints must not be portable")
        }
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains(binding.id.uuidString))

        let restoredCount = try await backup.restore(from: package.data)
        XCTAssertEqual(restoredCount, 17)
        let after = try await destination.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM metric_sample ORDER BY id")
        }
        XCTAssertEqual(after, before, "Compare real columns, not two copies of the export whitelist")
        let connection = try await HealthImportStore(writer: destination.writer).connection()
        XCTAssertNil(connection, "Restored device readings do not establish read access or a connection")
        try await destination.writer.read { db in
            for table in ["hk_import_binding", "hk_sync_anchor", "hk_sample_index", "alert_event"] {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"), 0)
            }
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }

        let trends = TrendQueryStore(writer: destination.writer)
        let range = DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000),
                                 end: Date(timeIntervalSince1970: 1_701_000_000))
        let systolic = try await trends.series(for: member, metric: .bloodPressureSys, range: range)
        let diastolic = try await trends.series(for: member, metric: .bloodPressureDia, range: range)
        XCTAssertEqual(systolic.points.map(\.value), [128])
        XCTAssertEqual(diastolic.points.map(\.value), [82])
        let glucose = try await trends.series(for: member, metric: .glucose, range: range)
        XCTAssertEqual(Set(glucose.referenceBands.map(\.sourceLabel)), ["Lab A", "Lab B"])
        let heartRate = try await trends.series(for: patient, metric: .heartRate, range: range)
        XCTAssertTrue(heartRate.points.isEmpty)
        XCTAssertEqual(heartRate.excludedPoints.map(\.value), [72.5])
    }

    func test_metricAdoptReplacesAllColumnsAndRemapsBothPatients() async throws {
        let (source, patient, member) = try await makeMetricStore()
        let package = try await BackupService(writer: source.writer).createBackup()
        let destination = try GRDBStore.inMemory()
        try await GRDBCodeIndex(writer: destination.writer).loadBundledSeedsIfNeeded()
        let backup = BackupService(writer: destination.writer)
        try await backup.restore(from: package.data)
        try await destination.writer.write { db in
            try db.execute(sql: """
                UPDATE metric_sample SET patient_id = ?, metric_key = 'local', value = 1, secondary_value = 2,
                  unit = 'old', origin = CASE WHEN origin = 'hospital' THEN 'device' ELSE 'hospital' END,
                  self_measured = CASE WHEN origin = 'hospital' THEN 1 ELSE 0 END, excluded = 1 - excluded,
                  source_ref = 'local-ref', ref_low = 3, ref_high = 4, ref_source_label = 'Local lab',
                  raw_label = 'local label', code_concept_id = 'c-hgb', value_min = 5, value_max = 6,
                  sample_count = 99, source_name = 'Local source', source_version = 'old-version',
                  source_product = 'old-product', source_identifier = 'old-id', aggregation_kind = 'sample',
                  window_end = 200, measured_at = 100, created_at = 150
                """, arguments: [patient.uuidString])
        }
        let analysis = try await backup.analyzeConflicts(from: package.data)
        XCTAssertEqual(analysis.conflicts.filter { $0.table == "metric_sample" }.count, 14)
        var resolutions = Dictionary(uniqueKeysWithValues: analysis.conflicts.map { ($0.id, ExportService.ConflictResolution.adopt) })
        resolutions[patient] = .coexist
        resolutions[member] = .coexist
        try await backup.restore(envelope: analysis.envelope, resolutions: resolutions)

        let remapped = try await destination.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, display_name FROM patient_profile WHERE id NOT IN (?, ?)",
                             arguments: [patient.uuidString, member.uuidString])
        }
        XCTAssertEqual(remapped.count, 2)
        let newPatient = try XCTUnwrap(remapped.first { ($0["display_name"] as String) == "Owner" })
        let newMember = try XCTUnwrap(remapped.first { ($0["display_name"] as String) == "Family" })
        let patientMap = [patient: try XCTUnwrap(UUID(uuidString: newPatient["id"])),
                         member: try XCTUnwrap(UUID(uuidString: newMember["id"]))]
        var expected = analysis.envelope.metrics
        for index in expected.indices {
            expected[index].patientId = patientMap[try XCTUnwrap(expected[index].patientId)]
        }
        let actual = try await ExportService(writer: destination.writer).exportJSON()
        XCTAssertEqual(actual.metrics.sorted { $0.id.uuidString < $1.id.uuidString },
                       expected.sorted { $0.id.uuidString < $1.id.uuidString })
        XCTAssertEqual(actual.owner?.selfPatientId, patientMap[patient])
    }

    func test_metricCoexistRemapsPatientButKeepsHealthIdentityAndLocalRow() async throws {
        let (store, patient, _) = try await makeMetricStore()
        let backup = BackupService(writer: store.writer)
        let package = try await backup.createBackup()
        let analysis = try await backup.analyzeConflicts(from: package.data)
        let metric = try XCTUnwrap(analysis.envelope.metrics.first { $0.key == "heartRate" })
        let before = try await store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM metric_sample WHERE id = ?", arguments: [metric.id.uuidString])
        }
        var resolutions = Dictionary(uniqueKeysWithValues: analysis.conflicts.map { ($0.id, ExportService.ConflictResolution.keep) })
        resolutions[patient] = .coexist
        resolutions[metric.id] = .coexist
        try await backup.restore(envelope: analysis.envelope, resolutions: resolutions)

        let result = try await ExportService(writer: store.writer).exportJSON()
        let copiedPatient = try XCTUnwrap(result.members?.first { $0.displayName == "Owner" && $0.id != patient })
        let copied = try XCTUnwrap(result.metrics.first { $0.patientId == copiedPatient.id })
        XCTAssertNotEqual(copied.id, metric.id)
        var expected = metric
        expected.id = copied.id
        expected.patientId = copiedPatient.id
        XCTAssertEqual(copied, expected, "Coexist must preserve the stable sourceRef and excluded flag")
        XCTAssertEqual(result.metrics.count, 15)
        let after = try await store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM metric_sample WHERE id = ?", arguments: [metric.id.uuidString])
        }
        XCTAssertEqual(after, before)
        XCTAssertEqual(result.owner?.selfPatientId, patient, "Coexist is not a new HealthKit owner binding")
    }

    func test_legacyOptionalFieldsRestoreAndAdoptWithMappedSelfFallback() async throws {
        let (source, patient, _) = try await makeStore()
        let exporter = ExportService(writer: source.writer)
        let original = try await exporter.exportJSON()
        let data = try await exporter.encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "owner")
        json.removeValue(forKey: "members")
        json.removeValue(forKey: "alertEvents")
        json["metrics"] = ["device", "hospital", "manual"].map { origin -> [String: Any] in
            ["id": UUID().uuidString, "key": "heart_rate", "value": 80, "unit": "bpm",
             "origin": origin, "measuredAt": 0, "excluded": true, "sourceRef": "legacy-\(origin)"]
        }
        let legacy = try await exporter.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.alertEvents)
        let destination = try GRDBStore.inMemory()
        let backup = BackupService(writer: destination.writer)
        let count = try await backup.restore(envelope: legacy)
        XCTAssertEqual(count, 4)

        // Exercise both INSERT and adopt, including a legacy nil patientId and no owner row.
        for adopting in [false, true] {
            if adopting {
                try await destination.writer.write { db in
                    try db.execute(sql: """
                        UPDATE metric_sample SET
                          origin = CASE WHEN origin = 'hospital' THEN 'device' ELSE 'hospital' END,
                          self_measured = CASE WHEN origin = 'hospital' THEN 1 ELSE 0 END
                        """)
                }
                var resolutions = Dictionary(uniqueKeysWithValues: legacy.metrics.map { ($0.id, ExportService.ConflictResolution.adopt) })
                resolutions[patient] = .coexist
                try await backup.restore(envelope: legacy, resolutions: resolutions)
            }
            let targetPatient = try await destination.writer.read { db in
                try String.fetchOne(db, sql: "SELECT id FROM patient_profile ORDER BY rowid DESC LIMIT 1")
            }
            if adopting { XCTAssertNotEqual(targetPatient, patient.uuidString) }
            try await destination.writer.read { db in
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM metric_sample ORDER BY origin")
                XCTAssertEqual(rows.count, 3)
                XCTAssertEqual(rows.map { $0["self_measured"] as Int }, [1, 0, 1])
                for row in rows {
                    XCTAssertEqual(row["patient_id"] as String?, targetPatient)
                    XCTAssertEqual(row["metric_key"] as String, "heart_rate", "Legacy keys are not normalized on restore")
                    XCTAssertEqual(row["excluded"] as Int, 1)
                    XCTAssertEqual(row["source_ref"] as String, "legacy-\(row["origin"] as String)")
                    XCTAssertEqual(row["measured_at"] as Double, 978_307_200)
                    XCTAssertEqual(row["created_at"] as Double, 978_307_200)
                    for column in ["secondary_value", "ref_low", "ref_high", "ref_source_label", "raw_label",
                                   "code_concept_id", "value_min", "value_max", "sample_count", "source_name",
                                   "source_version", "source_product", "source_identifier", "aggregation_kind", "window_end"] {
                        XCTAssertEqual(row[column] as DatabaseValue, .null, "Missing legacy \(column) must stay unknown")
                    }
                }
            }
        }
    }

    func test_missingCodeDictionaryRejectsRestoreAtomicallyInsteadOfDiscardingTheCode() async throws {
        let (source, _, _) = try await makeMetricStore()
        let package = try await BackupService(writer: source.writer).createBackup()
        let destination = try GRDBStore.inMemory()
        do {
            try await BackupService(writer: destination.writer).restore(from: package.data)
            XCTFail("A missing referenced concept must not silently become an unconfirmed metric")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
        try await destination.writer.read { db in
            for table in ["local_owner", "patient_profile", "metric_sample"] {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"), 0)
            }
        }
    }

    private func makeAlertStore() async throws -> (store: GRDBStore, patient: UUID, member: UUID) {
        let (store, patient, member) = try await makeStore()
        let evidence = """
            { "severity":"L2", "levelTag":"L2", "metricKey":"heart_rate", "value":142,
              "unit":"bpm", "origin":"device", "measuredAt":721699200,
              "guidelineID":"6C089EF0-0782-4BB1-9A3F-F6FD73C626A0", "guidelineVersion":"historical-v1",
              "citationURL":"https://example.invalid/historical-rule", "sourceIdentifier":"com.example.watch",
              "sampleID":"saved-sample", "episodeStart":721698600, "futureEvidence":{"kept":true} }
            """
        let legacyEvidence = """
            { "severity":"L3", "facts":"Legacy facts", "sourceRef":"Legacy citation",
              "suggestedPath":"Legacy path", "disclaimer":"Historical evaluation", "unknown":[1,2] }
            """
        let events: [(state: String, severity: String, qualified: Int, patient: UUID, evidence: String, scheduled: Double?)] = [
            ("pending", "L2", 1, patient, evidence, nil),
            ("deferred", "L2", 1, patient, evidence, 1_700_020_000),
            ("scheduled", "L2", 1, patient, evidence, 1_700_010_050),
            ("delivered", "L2", 1, patient, evidence, 1_700_010_060),
            ("failed", "L2", 1, patient, evidence, nil),
            ("pending", "L3", 0, member, legacyEvidence, nil),
            ("pending", "L0", 0, member, "{\"severity\":\"L0\",\"levelTag\":\"L0\"}", nil),
        ]
        try await store.writer.write { db in
            for (index, event) in events.enumerated() {
                try db.execute(sql: """
                    INSERT INTO alert_event
                      (id, patient_id, rule_id, severity, evidence_json, qualified, delivered_state, scheduled_at, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, event.patient.uuidString, "historical-rule-\(index)",
                        event.severity, event.evidence, event.qualified, event.state, event.scheduled,
                        1_700_010_000 + Double(index)])
            }
        }
        return (store, patient, member)
    }

    func test_alertHistoryRoundTripsButIsNotEligibleForNotificationRetry() async throws {
        let (source, patient, member) = try await makeAlertStore()
        let pendingBefore = try await GuidelineStore(writer: source.writer).history(
            patientId: patient, qualifiedOnly: true, pendingOnly: true, activeOnly: true)
        XCTAssertEqual(pendingBefore.count, 2, "The fixture must be eligible before backup")
        let expected = try await source.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, patient_id, rule_id, severity, evidence_json, qualified,
                       CASE WHEN delivered_state IN ('pending','deferred') THEN 'restored'
                            ELSE delivered_state END AS delivered_state, scheduled_at, created_at
                FROM alert_event ORDER BY id
                """)
        }
        let package = try await BackupService(writer: source.writer).createBackup()
        let destination = try GRDBStore.inMemory()
        let backup = BackupService(writer: destination.writer)
        let analysis = try await backup.analyzeConflicts(from: package.data)
        XCTAssertEqual(analysis.envelope.alertEvents?.count, 7)
        XCTAssertEqual(analysis.envelope.alertEvents?.filter { $0.deliveredState == "pending" }.count, 3)
        let count = try await backup.restore(from: package.data)
        XCTAssertEqual(count, 10, "Alert history contributes to the restore report")
        let actual = try await destination.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, patient_id, rule_id, severity, evidence_json, qualified,
                       delivered_state, scheduled_at, created_at
                FROM alert_event ORDER BY id
                """)
        }
        XCTAssertEqual(actual, expected, "Evidence must survive verbatim, including unknown and legacy keys")
        XCTAssertEqual(actual.sorted { ($0["rule_id"] as String) < ($1["rule_id"] as String) }
            .map { $0["delivered_state"] as String },
            ["restored", "restored", "scheduled", "delivered", "failed", "restored", "restored"])
        let guidelines = GuidelineStore(writer: destination.writer)
        let qualified = try await guidelines.history(patientId: patient, qualifiedOnly: true)
        XCTAssertEqual(qualified.count, 5, "Restoring delivery state must not rewrite historical qualification")
        let active = try await guidelines.history(patientId: patient, qualifiedOnly: true, activeOnly: true)
        XCTAssertTrue(active.isEmpty, "Restored history must not become newly pinned reminders")
        let legacy = try await guidelines.history(patientId: member)
        XCTAssertEqual(legacy.count, 2)
        XCTAssertEqual(legacy.first { $0.severity == .L3 }?.card.legacyFacts, "Legacy facts")
        for id in [patient, member] {
            let pending = try await guidelines.history(patientId: id, qualifiedOnly: true,
                                                       pendingOnly: true, activeOnly: true)
            XCTAssertTrue(pending.isEmpty, "Use the real notification retry query, independently of the medical review gate")
        }
    }

    func test_alertConflictsRequireResolutionAndKeepAdoptCoexistRemapSafely() async throws {
        let (store, patient, member) = try await makeAlertStore()
        let backup = BackupService(writer: store.writer)
        let package = try await backup.createBackup()
        let analysis = try await backup.analyzeConflicts(from: package.data)
        XCTAssertEqual(analysis.conflicts.filter { $0.table == "alert_event" }.count, 7)
        let events = try XCTUnwrap(analysis.envelope.alertEvents)
        let adopt = try XCTUnwrap(events.first { $0.ruleId == "historical-rule-0" })
        let coexist = try XCTUnwrap(events.first { $0.ruleId == "historical-rule-1" })
        let keep = try XCTUnwrap(events.first { $0.ruleId == "historical-rule-2" })
        let existingIDs = Set(events.map(\.id))
        try await store.writer.write { db in
            for id in [adopt.id, coexist.id, keep.id] {
                try db.execute(sql: """
                    UPDATE alert_event SET patient_id = ?, rule_id = 'local-rule', severity = 'L1',
                      evidence_json = '{"severity":"L1","levelTag":"L1","facts":"Local facts"}',
                      qualified = 1, delivered_state = 'pending', scheduled_at = 100, created_at = 50 WHERE id = ?
                    """, arguments: [member.uuidString, id.uuidString])
            }
        }
        let before = try await store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM alert_event ORDER BY id")
        }
        let nonEventResolutions = Dictionary(uniqueKeysWithValues: analysis.conflicts
            .filter { $0.table != "alert_event" }.map { ($0.id, ExportService.ConflictResolution.keep) })
        do {
            try await backup.restore(envelope: analysis.envelope, resolutions: nonEventResolutions)
            XCTFail("An unresolved alert collision must reject the entire restore")
        } catch BackupService.BackupError.conflictDetected { }
        let afterRejection = try await store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM alert_event ORDER BY id")
        }
        XCTAssertEqual(afterRejection, before)

        var resolutions = Dictionary(uniqueKeysWithValues: analysis.conflicts.map { ($0.id, ExportService.ConflictResolution.keep) })
        resolutions[patient] = .coexist
        resolutions[try XCTUnwrap(analysis.envelope.owner).id] = .adopt
        resolutions[adopt.id] = .adopt
        resolutions[coexist.id] = .coexist
        try await backup.restore(envelope: analysis.envelope, resolutions: resolutions)
        let result = try await ExportService(writer: store.writer).exportJSON()
        let mappedPatient = try XCTUnwrap(result.owner?.selfPatientId)
        XCTAssertNotEqual(mappedPatient, patient)
        let restoredEvents = try XCTUnwrap(result.alertEvents)
        XCTAssertEqual(restoredEvents.count, 8)
        let adopted = try XCTUnwrap(restoredEvents.first { $0.id == adopt.id })
        var expectedAdopt = adopt
        expectedAdopt.patientId = mappedPatient
        expectedAdopt.deliveredState = "restored"
        XCTAssertEqual(adopted, expectedAdopt)
        let copied = try XCTUnwrap(restoredEvents.first { !existingIDs.contains($0.id) })
        var expectedCoexist = coexist
        expectedCoexist.id = copied.id
        expectedCoexist.patientId = mappedPatient
        expectedCoexist.deliveredState = "restored"
        XCTAssertEqual(copied, expectedCoexist)
        let after = try await store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM alert_event ORDER BY id")
        }
        for id in [keep.id, coexist.id] {
            XCTAssertEqual(after.first { ($0["id"] as String) == id.uuidString },
                           before.first { ($0["id"] as String) == id.uuidString },
                           "Keep and the original half of coexist must remain untouched")
        }
        let pending = try await GuidelineStore(writer: store.writer).history(
            patientId: mappedPatient, qualifiedOnly: true, pendingOnly: true, activeOnly: true)
        XCTAssertTrue(pending.isEmpty)
    }
}
