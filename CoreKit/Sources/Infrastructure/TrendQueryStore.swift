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
            // 舒张压无独立行：值存于收缩压行的 secondary_value（FR7.11 血压
            // 双序列——此前舒张压系列恒空、双线缺失）。列标识为白名单字面量
            // 插值（非用户输入，无注入面）。
            let (keyToQuery, valueColumn, refProjection) = metric == .bloodPressureDia
                ? (MetricType.bloodPressureSys.rawValue, "secondary_value",
                   "NULL AS ref_low, NULL AS ref_high, NULL AS ref_source_label")
                : (metric.rawValue, "value", "ref_low, ref_high, ref_source_label")
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, metric_key, \(valueColumn) AS value, secondary_value, unit, origin, self_measured,
                       measured_at, excluded, source_ref, \(refProjection),
                       raw_label, code_concept_id
                FROM metric_sample
                WHERE patient_id = ? AND metric_key = ? AND \(valueColumn) IS NOT NULL
                  AND measured_at >= ? AND measured_at <= ?
                ORDER BY measured_at ASC
                """, arguments: [member.uuidString, keyToQuery,
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
                    refSourceLabel: row["ref_source_label"] as String?,
                    rawLabel: row["raw_label"] as String?,
                    codeConceptId: row["code_concept_id"] as String?)
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
                   self_measured, measured_at, excluded, source_ref, created_at)
                VALUES (?, ?, ?, ?, ?, ?, 'manual', 1, ?, 0, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString, metric.rawValue, value,
                                 secondaryValue, unit, measuredAt.timeIntervalSince1970, sourceRef,
                                 Date().timeIntervalSince1970])
        }
        return id
    }

    // MARK: - FR7.9 设备自动汇入（V3.86：与手输同一写门，origin='device'）

    /// 设备读数落库（小时窗口聚合后，Domain `DeviceMetricRow`）。
    /// 幂等键含来源（patient, metric_key, measured_at, source_name）——
    /// 同一窗口重拉 upsert（INSERT ... ON CONFLICT 需要唯一索引才能生效，
    /// 此处以「先查后插」实现幂等：同键已有行则 UPDATE 值域——同步重放
    /// 不产生重复行也不丢更完整的后到数据）。单事务（UnitOfWork 语义）。
    /// 键归一化：设备侧 snake_case 键（heart_rate 等）经 MetricType(grammarKey:)
    /// 映射为趋势层 camelCase rawValue（heartRate）——与手输同键同系列，
    /// 否则宫格出现并列第二块未本地化 raw 键瓷片、详情页拒载（K1 修复）。
    public func addDeviceSamples(patientId: UUID,
                                 rows: [DeviceMetricRow]) async throws -> Int {
        // Swift 6 收敛：写闭包并发执行——计数为闭包局部量、随返回值传出
        // （变异捕获 var 在 Swift 6 语言模式转硬错误，34194157030 唯一警告族）
        return try await writer.write { db -> Int in
            var inserted = 0
            for row in rows {
                // 键归一化：趋势层单一事实源 MetricType 覆盖的键统一到 rawValue；
                // 未覆盖键（steps/sleep_total 等无趋势页指标）保持原键
                let metricKey = MetricType(grammarKey: row.metricKey)?.rawValue ?? row.metricKey
                let existing = try Row.fetchOne(db, sql: """
                    SELECT id, value FROM metric_sample
                    WHERE patient_id = ? AND metric_key = ? AND measured_at = ?
                      AND (source_name = ? OR (source_name IS NULL AND ? IS NULL))
                    LIMIT 1
                    """, arguments: [patientId.uuidString, metricKey,
                                     row.measuredAt.timeIntervalSince1970,
                                     row.sourceName, row.sourceName])
                if let existing {
                    // 重放更新值域（metric_sample 无 updated_at 列——V3.86 DDL）
                    try db.execute(sql: """
                        UPDATE metric_sample
                        SET value = ?, value_min = ?, value_max = ?, sample_count = ?,
                            source_version = ?, source_product = ?
                        WHERE id = ?
                        """, arguments: [row.value, row.valueMin, row.valueMax, row.sampleCount,
                                         row.sourceVersion, row.sourceProduct, existing["id"]])
                } else {
                    try db.execute(sql: """
                        INSERT INTO metric_sample
                          (id, patient_id, metric_key, value, secondary_value, unit, origin,
                           self_measured, excluded, value_min, value_max, sample_count,
                           source_name, source_version, source_product, measured_at, created_at)
                        VALUES (?, ?, ?, ?, NULL, ?, 'device', 1, 0, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [UUID().uuidString, patientId.uuidString, metricKey,
                                         row.value, row.unit, row.valueMin, row.valueMax,
                                         row.sampleCount, row.sourceName, row.sourceVersion,
                                         row.sourceProduct, row.measuredAt.timeIntervalSince1970,
                                         Date().timeIntervalSince1970])
                    inserted += 1
                }
                // 同窗旧来源行清理：同一 (metric_key, measured_at) 只保留最新
                // 聚合行（来源占多翻转/重放时旧 partial 行删除，手输行 origin
                // 非 device 不受影响）
                try db.execute(sql: """
                    DELETE FROM metric_sample
                    WHERE patient_id = ? AND metric_key = ? AND measured_at = ?
                      AND origin = 'device'
                      AND NOT (source_name IS ? OR (source_name IS NULL AND ? IS NULL))
                    """, arguments: [patientId.uuidString, metricKey,
                                     row.measuredAt.timeIntervalSince1970,
                                     row.sourceName, row.sourceName])
            }
            return inserted
        }
    }
}


/// §5.45 指标总览宫格数据源（V3.72）：每个已录入指标的最新点（值/单位/来源），
/// 用于 MetricTile 大数字 + 来源点渲染。未录入的指标不产出行（宫格只显示有数据项，
/// 空态由视图层引导 [快速录入]）。
extension TrendQueryStore {
    public struct LatestMetric: Sendable, Equatable, Identifiable {
        public let metricKey: String
        public let value: Double
        /// 血压第二值（收缩压行的舒张压；其余指标 nil）——宫格双值变体
        /// （ui-ux 4.10）数据源
        public let secondaryValue: Double?
        public let unit: String?
        public let origin: String
        public let measuredAt: Date
        public var id: String { metricKey }
        public init(metricKey: String, value: Double, secondaryValue: Double? = nil,
                    unit: String?, origin: String, measuredAt: Date) {
            self.metricKey = metricKey
            self.value = value
            self.secondaryValue = secondaryValue
            self.unit = unit
            self.origin = origin
            self.measuredAt = measuredAt
        }
    }

    /// SP-13 未连接空态判定（FR16.1 / ui-ux §5.45 V3.53）：成员名下是否
    /// 存在任何 origin='device' 读数。无设备读数 = 从未连接/未同步过
    /// Apple 健康——趋势详情空态分流为「未连接」+ 去连接深链，而非通用
    /// 无数据（有设备数据但该指标空 → 仍走通用空态）。
    public func hasDeviceSamples(patientId: UUID) async throws -> Bool {
        try await writer.read { db in
            let exists = try Int.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM metric_sample
                              WHERE patient_id = ? AND origin = 'device' AND excluded = 0)
                """, arguments: [patientId.uuidString]) ?? 0
            return exists == 1
        }
    }

    public func latestPerMetric(patientId: UUID) async throws -> [LatestMetric] {
        try await writer.read { db in
            // 第六轮全仓审查修复：MAX(measured_at) 等值 JOIN 在同一时刻存在
            // 多条样本时返回重复行（每分钟粒度录入器可达成）——同 key 重复
            // id 让指标宫格 ForEach 崩溃/重砖。改「每个 key 单行 id 子查询」，
            // 同刻并列取 rowid 最新的一条。
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.metric_key, m.value, m.secondary_value, m.unit, m.origin, m.measured_at
                FROM metric_sample m
                WHERE m.patient_id = ? AND m.excluded = 0
                  AND m.id = (SELECT m2.id FROM metric_sample m2
                              WHERE m2.patient_id = ? AND m2.excluded = 0
                                AND m2.metric_key = m.metric_key
                              ORDER BY m2.measured_at DESC, m2.rowid DESC
                              LIMIT 1)
                ORDER BY m.measured_at DESC
                """, arguments: [patientId.uuidString, patientId.uuidString])
            return rows.map { row in
                LatestMetric(metricKey: row["metric_key"] as String,
                             value: row["value"] as Double,
                             secondaryValue: row["secondary_value"] as Double?,
                             unit: row["unit"] as String?,
                             origin: row["origin"] as String,
                             measuredAt: Date(timeIntervalSince1970: row["measured_at"] as Double))
            }
        }
    }
}
#endif
