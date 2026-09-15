#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

/// 读面扩展：SQL 只留在仓储侧，行解码后返回 Domain 读模型
/// （HealthTypeSummary / HealthImportDashboard / HealthImportRow——
/// 结构轮 2026-09-15 自本文件迁入 Domain，UI 不再依赖 Infrastructure 内部类型）。
extension HealthImportStore {

    /// Local read face remains available when HealthKit permission/automatic import is disabled.
    public func dashboard() async throws -> HealthImportDashboard {
        try await writer.read { db in
            guard let owner = try Self.ownerPatient(db) else { throw ImportError.missingOwner }
            let binding = try Self.binding(db)
            var types: [HealthTypeSummary] = []
            for kind in HealthDataKind.allCases {
                let row = try Row.fetchOne(db, sql: """
                    SELECT COUNT(*) AS n, MAX(measured_at) AS last_at FROM metric_sample
                    WHERE patient_id = ? AND origin = 'device' AND source_ref LIKE ? AND excluded = 0
                    """, arguments: [owner.uuidString, "hk:\(kind.rawValue):%"])
                types.append(.init(kind: kind, rowCount: row?["n"] ?? 0,
                    latestAt: (row?["last_at"] as Double?).map(Date.init(timeIntervalSince1970:))))
            }
            var report: SyncReport?
            if let binding, binding.patientId == owner,
               let json = try String.fetchOne(db, sql: "SELECT report_json FROM hk_import_status WHERE binding_id = ?", arguments: [binding.id.uuidString]) {
                report = try JSONDecoder().decode(SyncReport.self, from: Data(json.utf8))
                if report?.bindingId != binding.id || report?.patientId != owner { report = nil }
            }
            return .init(patientId: owner,
                ownerName: try String.fetchOne(db, sql: "SELECT display_name FROM patient_profile WHERE id = ?", arguments: [owner.uuidString]) ?? "",
                connected: binding?.patientId == owner, bindingId: binding?.patientId == owner ? binding?.id : nil,
                types: types, lastReport: report)
        }
    }

    public func importedRows(kind: HealthDataKind, before: HealthImportRow? = nil, limit: Int = 100) async throws -> [HealthImportRow] {
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
                SELECT id, metric_key, value, unit, measured_at, source_name,
                       aggregation_kind, window_end, value_min, value_max, sample_count
                FROM metric_sample
                WHERE patient_id = ? AND origin = 'device' AND source_ref LIKE ? AND excluded = 0 \(cursor)
                ORDER BY measured_at DESC, id DESC LIMIT ?
                """, arguments: StatementArguments(arguments)).compactMap { row -> HealthImportRow? in
                guard let id = UUID(uuidString: row["id"] as String) else { return nil }
                // FR7.9 统计事实随行投影（2026-09-15 实测修复）：设备行须能自述是单条读数、
                // 小时均值、日累计还是睡眠时段时长，并带窗口结束时间、极值与有效样本数。
                // 显式类型标注 + 分步构造（CI 实证：12 参初始化器内联 flatMap/map 触发
                // 「unable to type-check in reasonable time」——L0 家族 G 同族）。
                let value: Double = row["value"]
                let unit: String = row["unit"] ?? ""
                let measuredAt = Date(timeIntervalSince1970: row["measured_at"] as Double)
                let sourceName: String? = row["source_name"]
                let aggregation: MetricAggregation? = (row["aggregation_kind"] as String?).flatMap(MetricAggregation.init(rawValue:))
                let windowEnd: Date? = (row["window_end"] as Double?).map { Date(timeIntervalSince1970: $0) }
                let valueMin: Double? = row["value_min"]
                let valueMax: Double? = row["value_max"]
                let sampleCount: Int? = row["sample_count"]
                return .init(id: id, patientId: owner, metricKey: row["metric_key"] as String, value: value, unit: unit,
                             measuredAt: measuredAt, sourceName: sourceName,
                             aggregation: aggregation, windowEnd: windowEnd,
                             valueMin: valueMin, valueMax: valueMax, sampleCount: sampleCount)
            }
        }
    }

    func saveReport(_ report: SyncReport) async throws {
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
