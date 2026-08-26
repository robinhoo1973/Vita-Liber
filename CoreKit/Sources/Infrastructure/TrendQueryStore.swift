#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F7 指标趋势 GRDB 查询层（§5.29）：成员隔离、排除点软删（excluded=0）、
/// 报告自带参考范围（A 级）优先、换算只发生在查询层。
public actor TrendQueryStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public func series(for member: UUID, metric: MetricType,
                       range: DateInterval) async throws -> TrendSeries {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, metric_key, value, secondary_value, unit, origin, self_measured,
                       measured_at, excluded, source_ref
                FROM metric_sample
                WHERE patient_id = ? AND metric_key = ?
                  AND measured_at >= ? AND measured_at <= ?
                ORDER BY measured_at ASC
                """, arguments: [member.uuidString, metric.rawValue,
                                 range.start.timeIntervalSince1970, range.end.timeIntervalSince1970])
            let points = rows.map { row in
                TrendPoint(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    measuredAt: Date(timeIntervalSince1970: row["measured_at"] as Double),
                    value: row["value"] as Double,
                    origin: MetricOrigin(rawValue: row["origin"] as String) ?? .manual,
                    excluded: (row["excluded"] as Int?) == 1,
                    sourceRef: row["source_ref"] as String?)
            }
            return TrendSeries(metricType: metric, points: TrendRules.visible(points))
        }
    }

    /// 排除/恢复（软删语义：保留原值，动作记审计由调用方写 audit_event）
    public func setExcluded(_ id: UUID, excluded: Bool) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE metric_sample SET excluded = ? WHERE id = ?",
                           arguments: [excluded ? 1 : 0, id.uuidString])
        }
    }
}
#endif
