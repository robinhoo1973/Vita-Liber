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

    /// F7 趋势查询。返回可见点 + **各自独立**的 A 级参考带（FR7.2）+ 排除点对照集。
    /// - Parameter libraryFallback: 无任何 A 级带时的 B 级信源库缺省带（P1 上线前传 nil；
    ///   P0.5 阶段自测/设备读数不显示通用参考范围——function-spec F7「参考范围时序」）。
    public func series(for member: UUID, metric: MetricType,
                       range: DateInterval,
                       libraryFallback: ReferenceBand? = nil) async throws -> TrendSeries {
        try await writer.read { db in
            // 一次取全量（含 excluded），在内存里分流为可见集/排除集——
            // 两次查询会在并发写入下取到不一致的两个快照。
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, metric_key, value, secondary_value, unit, origin, self_measured,
                       measured_at, excluded, source_ref, ref_low, ref_high, ref_source_label
                FROM metric_sample
                WHERE patient_id = ? AND metric_key = ?
                  AND measured_at >= ? AND measured_at <= ?
                ORDER BY measured_at ASC
                """, arguments: [member.uuidString, metric.rawValue,
                                 range.start.timeIntervalSince1970, range.end.timeIntervalSince1970])
            let all = rows.map { row in
                TrendPoint(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    measuredAt: Date(timeIntervalSince1970: row["measured_at"] as Double),
                    value: row["value"] as Double,
                    unit: row["unit"] as String?,
                    origin: MetricOrigin(rawValue: row["origin"] as String) ?? .manual,
                    excluded: (row["excluded"] as Int?) == 1,
                    sourceRef: row["source_ref"] as String?,
                    refLow: row["ref_low"] as Double?,
                    refHigh: row["ref_high"] as Double?,
                    refSourceLabel: row["ref_source_label"] as String?)
            }
            let visible = TrendRules.visible(all)
            return TrendSeries(
                metricType: metric,
                points: visible,
                // 参考带只从**可见点**提取：排除点通常是 OCR 错值，其携带的
                // 参考范围同样不可信，不应继续画在图上。
                referenceBands: TrendRules.resolveBands(points: visible,
                                                        libraryFallback: libraryFallback),
                excludedPoints: all.filter(\.excluded))
        }
    }

    /// 排除/恢复（软删语义：保留原值，动作记审计由调用方写 audit_event）
    /// 评审修正：带 patient_id 成员隔离（BR-001）
    public func setExcluded(_ id: UUID, patientId: UUID, excluded: Bool) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE metric_sample SET excluded = ? WHERE id = ? AND patient_id = ?",
                           arguments: [excluded ? 1 : 0, id.uuidString, patientId.uuidString])
        }
    }

    // MARK: - FR7.5 自测两步录入（C 级 + selfMeasured 标志 + 单位记忆）

    /// 自测/手输指标入库。来源语义（FR7.6）：自测数据固定 C 级并携带
    /// self_measured 标志，趋势图以空心点区分医院实心点。
    /// P0.5 阶段无通用参考范围（FR7.2 时序）：ref_* 一律 NULL。
    public func addSample(patientId: UUID, metric: MetricType, value: Double,
                          secondaryValue: Double?, unit: String,
                          measuredAt: Date, sourceRef: String? = nil) async throws -> UUID {
        let id = UUID()
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO metric_sample
                  (id, patient_id, metric_key, value, secondary_value, unit, origin,
                   self_measured, measured_at, excluded, source_ref)
                VALUES (?, ?, ?, ?, ?, ?, 'manual', 1, ?, 0, ?)
                """, arguments: [id.uuidString, patientId.uuidString, metric.rawValue, value,
                                 secondaryValue, unit, measuredAt.timeIntervalSince1970, sourceRef])
        }
        return id
    }
}
#endif
