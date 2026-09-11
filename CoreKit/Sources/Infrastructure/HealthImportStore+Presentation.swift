#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

extension HealthImportStore {
    public struct TypeSummary: Sendable, Identifiable {
        public let kind: HealthDataKind
        public let rowCount: Int
        public let latestAt: Date?
        public var id: HealthDataKind { kind }
    }
    public struct Dashboard: Sendable {
        public let patientId: UUID
        public let ownerName: String
        public let connected: Bool
        public let bindingId: UUID?
        public let types: [TypeSummary]
        public let lastReport: HealthKitSyncService.SyncReport?
    }
    public struct ImportedRow: Sendable, Identifiable {
        public let id: UUID
        public let patientId: UUID
        public let metricKey: String
        public let value: Double
        public let unit: String
        public let measuredAt: Date
        public let sourceName: String?
    }

    /// Local read face remains available when HealthKit permission/automatic import is disabled.
    public func dashboard() async throws -> Dashboard {
        try await writer.read { db in
            guard let owner = try Self.ownerPatient(db) else { throw ImportError.missingOwner }
            let binding = try Self.binding(db)
            var types: [TypeSummary] = []
            for kind in HealthDataKind.allCases {
                let row = try Row.fetchOne(db, sql: """
                    SELECT COUNT(*) AS n, MAX(measured_at) AS last_at FROM metric_sample
                    WHERE patient_id = ? AND origin = 'device' AND source_ref LIKE ? AND excluded = 0
                    """, arguments: [owner.uuidString, "hk:\(kind.rawValue):%"])
                types.append(.init(kind: kind, rowCount: row?["n"] ?? 0,
                    latestAt: (row?["last_at"] as Double?).map(Date.init(timeIntervalSince1970:))))
            }
            var report: HealthKitSyncService.SyncReport?
            if let binding, binding.patientId == owner,
               let json = try String.fetchOne(db, sql: "SELECT report_json FROM hk_import_status WHERE binding_id = ?", arguments: [binding.id.uuidString]) {
                report = try JSONDecoder().decode(HealthKitSyncService.SyncReport.self, from: Data(json.utf8))
                if report?.bindingId != binding.id || report?.patientId != owner { report = nil }
            }
            return .init(patientId: owner,
                ownerName: try String.fetchOne(db, sql: "SELECT display_name FROM patient_profile WHERE id = ?", arguments: [owner.uuidString]) ?? "",
                connected: binding?.patientId == owner, bindingId: binding?.patientId == owner ? binding?.id : nil,
                types: types, lastReport: report)
        }
    }

    public func importedRows(kind: HealthDataKind, before: ImportedRow? = nil, limit: Int = 100) async throws -> [ImportedRow] {
        try await writer.read { db in
            guard let owner = try Self.ownerPatient(db), before == nil || before?.patientId == owner else { throw ImportError.missingOwner }
            var arguments: [DatabaseValueConvertible] = [owner.uuidString, "hk:\(kind.rawValue):%"]
            var cursor = ""
            if let before {
                cursor = "AND (measured_at < ? OR (measured_at = ? AND id < ?))"
                arguments += [before.measuredAt.timeIntervalSince1970, before.measuredAt.timeIntervalSince1970, before.id.uuidString]
            }
            arguments.append(min(200, max(1, limit)))
            return try Row.fetchAll(db, sql: """
                SELECT id, metric_key, value, unit, measured_at, source_name FROM metric_sample
                WHERE patient_id = ? AND origin = 'device' AND source_ref LIKE ? AND excluded = 0 \(cursor)
                ORDER BY measured_at DESC, id DESC LIMIT ?
                """, arguments: StatementArguments(arguments)).compactMap { row -> ImportedRow? in
                guard let id = UUID(uuidString: row["id"] as String) else { return nil }
                return .init(id: id, patientId: owner, metricKey: row["metric_key"], value: row["value"], unit: row["unit"] ?? "",
                             measuredAt: Date(timeIntervalSince1970: row["measured_at"]), sourceName: row["source_name"])
            }
        }
    }

    func saveReport(_ report: HealthKitSyncService.SyncReport) async throws {
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        try await writer.write { db in
            guard let binding = try Self.binding(db), try Self.ownerPatient(db) == binding.patientId,
                  report.bindingId == binding.id, report.patientId == binding.patientId else { throw ImportError.bindingChanged }
            try db.execute(sql: """
                INSERT INTO hk_import_status (binding_id, report_json, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(binding_id) DO UPDATE SET report_json=excluded.report_json, updated_at=excluded.updated_at
                """, arguments: [binding.id.uuidString, json, report.lastSyncAt.timeIntervalSince1970])
        }
    }

    func automaticImportEnabled() async throws -> Bool {
        try await writer.read { db in
            let raw = try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?", arguments: [AppSettingKey.healthAutoImport.rawValue])
            return SettingsRules.resolved(raw, key: .healthAutoImport) == "true"
        }
    }
}
#endif
