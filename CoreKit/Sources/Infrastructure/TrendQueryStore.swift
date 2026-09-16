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

    /// round2 H2 / BR-001：显式设备过滤而成员非本人绑定 → 拒绝（不静默空态，视图据此不提供设备筛选项）
    public enum QueryError: Error { case deviceRequiresSelfBinding }

    /// F7 趋势查询（round2 H2：携查询身份）。返回可见点 + **各自独立**的 A 级参考带（FR7.2）
    /// + 排除点对照集；`result.identity == query` 供渲染层丢弃过期/错位结果。
    /// - Parameter libraryFallback: 无任何 A 级带时的 B 级信源库缺省带（P1 上线前传 nil；
    ///   P0.5 阶段自测/设备读数不显示通用参考范围——function-spec F7「参考范围时序」）。
    public func series(_ query: TrendQueryIdentity, libraryFallback: ReferenceBand? = nil) async throws -> TrendSeries {
        try await writer.read { db in
            // BR-001：设备读数只可能归属本人绑定。显式设备过滤而成员非本人 → 拒绝（不静默空态）；
            // 全来源查询对非本人成员过滤掉任何 device 行（旧备份/重映射残留不得跨成员呈现）。
            let isSelf = try HealthImportStore.ownerPatient(db) == query.patientId
            if query.origin == .device, !isSelf { throw QueryError.deviceRequiresSelfBinding }
            let metric = query.metric
            let range = query.range
            // 一次取全量（含 excluded），在内存里分流为可见集/排除集——
            // 两次查询会在并发写入下取到不一致的两个快照。
            // 舒张压无独立行：值存于收缩压行的 secondary_value（FR7.11 血压
            // 双序列——此前舒张压系列恒空、双线缺失）。列标识为白名单字面量
            // 插值（非用户输入，无注入面）；来源过滤子句为常量字面量，值经参数绑定。
            let (keyToQuery, valueColumn, refProjection) = metric == .bloodPressureDia
                ? (MetricType.bloodPressureSys.rawValue, "secondary_value",
                   "NULL AS ref_low, NULL AS ref_high, NULL AS ref_source_label")
                : (metric.rawValue, "value", "ref_low, ref_high, ref_source_label")
            let originClause = query.origin == nil ? "" : " AND origin = ?"
            var arguments: [DatabaseValueConvertible] = [query.patientId.uuidString, keyToQuery,
                                                         range.start.timeIntervalSince1970, range.end.timeIntervalSince1970]
            if let origin = query.origin { arguments.append(origin.rawValue) }
            var rows = try Row.fetchAll(db, sql: """
                SELECT id, metric_key, \(valueColumn) AS value, secondary_value, unit, origin, self_measured,
                       measured_at, excluded, source_ref, \(refProjection),
                       raw_label, code_concept_id, source_name, source_identifier,
                       aggregation_kind, window_end, value_min, value_max, sample_count
                FROM metric_sample
                WHERE patient_id = ? AND metric_key = ? AND \(valueColumn) IS NOT NULL
                  AND measured_at >= ? AND measured_at <= ?\(originClause)
                ORDER BY measured_at ASC
                """, arguments: StatementArguments(arguments))
            if metric == .bloodPressureDia {
                // 审查修复：单值舒张压（语音「低压 90」/自测单值）落库为
                // metric_key='bloodPressureDia' 独立行——而主查询只读收缩压行
                // 的 secondary_value，独立行在趋势图上永远缺席（读数存在、
                // 图表空态）。并查独立行后按时间归并；来源过滤同样套用。
                var directArguments: [DatabaseValueConvertible] = [query.patientId.uuidString,
                                                                   range.start.timeIntervalSince1970, range.end.timeIntervalSince1970]
                if let origin = query.origin { directArguments.append(origin.rawValue) }
                let direct = try Row.fetchAll(db, sql: """
                    SELECT id, metric_key, value AS value, secondary_value, unit, origin, self_measured,
                           measured_at, excluded, source_ref,
                           NULL AS ref_low, NULL AS ref_high, NULL AS ref_source_label,
                           raw_label, code_concept_id, source_name, source_identifier,
                           aggregation_kind, window_end, value_min, value_max, sample_count
                    FROM metric_sample
                    WHERE patient_id = ? AND metric_key = 'bloodPressureDia' AND value IS NOT NULL
                      AND measured_at >= ? AND measured_at <= ?\(originClause)
                    ORDER BY measured_at ASC
                    """, arguments: StatementArguments(directArguments))
                rows.append(contentsOf: direct)
                rows.sort { ($0["measured_at"] as Double) < ($1["measured_at"] as Double) }
            }
            let mapped = rows.map(Self.trendPoint)
            // BR-001：非本人成员名下的 device 行（可见与排除点集皆然）不得呈现
            let all = mapped.filter { $0.origin != .device || isSelf }
            let visible = TrendRules.visible(all)
            return TrendSeries(
                metricType: metric,
                points: visible,
                // 参考带只从**可见点**提取：排除点通常是 OCR 错值，其携带的
                // 参考范围同样不可信，不应继续画在图上。
                referenceBands: TrendRules.resolveBands(points: visible,
                                                        libraryFallback: libraryFallback),
                excludedPoints: all.filter(\.excluded),
                identity: query)
        }
    }

    /// 行 → 趋势点（唯一映射出口）：`series` 与 `sleepSeries` 共用——
    /// 睡眠整合查询若另写一份映射，两条读路径的字段口径立刻分叉
    /// （本仓「同一事实两处实现」的既有教训：血压舒张压系列曾经如此）。
    static func trendPoint(_ row: Row) -> TrendPoint {
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
            codeConceptId: row["code_concept_id"] as String?,
            sourceName: row["source_name"] as String?, sourceIdentifier: row["source_identifier"] as String?,
            aggregation: (row["aggregation_kind"] as String?).flatMap(MetricAggregation.init(rawValue:)),
            windowEnd: (row["window_end"] as Double?).map(Date.init(timeIntervalSince1970:)),
            valueMin: row["value_min"] as Double?, valueMax: row["value_max"] as Double?,
            sampleCount: row["sample_count"] as Int?)
    }

    /// 兼容包装（全来源）：既有调用方（宫格迷你图 / 趋势入口）不改；身份同样回传。
    public func series(for member: UUID, metric: MetricType,
                       range: DateInterval,
                       libraryFallback: ReferenceBand? = nil) async throws -> TrendSeries {
        try await series(TrendQueryIdentity(patientId: member, metric: metric, origin: nil, range: range),
                         libraryFallback: libraryFallback)
    }

    /// F7 睡眠整合查询（FR7.11，业主 2026-09-16 第 3 项）：一晚的六个时长投影键
    /// **一趟取回**（`metric_key IN (...)`，2 条语句：`ownerPatient` + 一次扫描）。
    ///
    /// 为什么不是六次 `series`：六个键同属一晚，六次往返 = 6×（ownerPatient + 全字段
    /// 映射 + 排序），页面/周期每次变化都付一遍；且六份结果的身份校验、排除集合并、
    /// 空态判据都要各自再拼一次（漂移源）。
    /// 口径与 `series` 完全一致：`excluded` 一并取回在内存分流（两次查询会在并发写入下
    /// 取到不一致快照）、BR-001 非本人名下的 device 行不计入。
    public func sleepSeries(_ query: TrendQueryIdentity) async throws -> SleepTrendSeries {
        try await writer.read { db in
            let isSelf = try HealthImportStore.ownerPatient(db) == query.patientId
            if query.origin == .device, !isSelf { throw QueryError.deviceRequiresSelfBinding }
            let keys = MetricType.sleepGroupKeys.map(\.rawValue)
            let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
            // 参数顺序与 SQL 占位顺序逐位对应：patient → IN 键集 → 窗起 → 窗止 → [来源]
            var keyArguments: [DatabaseValueConvertible] = [query.patientId.uuidString]
            keyArguments.append(contentsOf: keys)
            keyArguments.append(query.range.start.timeIntervalSince1970)
            keyArguments.append(query.range.end.timeIntervalSince1970)
            let originClause = query.origin == nil ? "" : " AND origin = ?"
            if let origin = query.origin { keyArguments.append(origin.rawValue) }
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, metric_key, value, secondary_value, unit, origin, self_measured,
                       measured_at, excluded, source_ref, ref_low, ref_high, ref_source_label,
                       raw_label, code_concept_id, source_name, source_identifier,
                       aggregation_kind, window_end, value_min, value_max, sample_count
                FROM metric_sample
                WHERE patient_id = ? AND metric_key IN (\(placeholders)) AND value IS NOT NULL
                  AND measured_at >= ? AND measured_at <= ?\(originClause)
                ORDER BY measured_at ASC
                """, arguments: StatementArguments(keyArguments))
            let all = rows.compactMap { row -> SleepTrendRow? in
                guard let metric = MetricType(rawValue: row["metric_key"] as String) else { return nil }
                let point = Self.trendPoint(row)
                // BR-001：非本人成员名下的 device 行不得呈现（与 series 同款）
                guard point.origin != .device || isSelf else { return nil }
                return SleepTrendRow(metric: metric, point: point)
            }
            return SleepTrendRules.series(all, identity: query)
        }
    }

    /// 排除/恢复（软删语义：保留原值，动作记审计由调用方写 audit_event）
    /// 评审修正：带 patient_id 成员隔离（BR-001）
    /// 成组排除/恢复（FR7.11 睡眠整合：动作粒度 = **一夜**，一页多行）：
    /// **单事务**（UnitOfWork 语义，与 `addDeviceSamples` 同纪律）——逐行各写一次时
    /// 中途失败会留下「半排除」的夜：图上仍是部分柱、已排除分段里也有它，
    /// 两个列表给出互相矛盾的读数，且调用方无从知道哪几行落了库。
    /// 带 patient_id 成员隔离（BR-001，与单行版同款）。
    public func setExcluded(_ ids: [UUID], patientId: UUID, excluded: Bool) async throws {
        guard !ids.isEmpty else { return }
        try await writer.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE metric_sample SET excluded = ? WHERE id = ? AND patient_id = ?",
                               arguments: [excluded ? 1 : 0, id.uuidString, patientId.uuidString])
            }
        }
    }

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

    // MARK: - FR6.9 V3.61 检验卡确认 → 医院来源行（origin='hospital', self_measured=0）

    /// 确认后的检验项目落库：A 级参考范围随行（ref_source_label = 医院），`source_ref`
    /// 回到文档页；编码仅在用户确认建议后回填（BR-003/FR25.11）。单事务，返回写入行数。
    public func addHospitalSamples(patientId: UUID, documentId: UUID, pageIndex: Int,
                                   samples: [HospitalSample]) async throws -> Int {
        let sourceRef = HospitalSample.sourceRef(documentId: documentId, pageIndex: pageIndex)
        return try await writer.write { db in
            try DocumentStore.validateSource(db, patientId: patientId, documentId: documentId, pageIndex: pageIndex)
            var written = 0
            for sample in samples {
                try Self.insertHospitalSample(sample, id: UUID(), patientId: patientId, sourceRef: sourceRef, db: db, now: Date())
                written += db.changesCount
            }
            return written
        }
    }

    /// v26（子项目 D §C.5）：`labReportId` 回指检验表头（同卡数值行共用一条 `lab_report`；旧路径 nil）；
    /// `abnormal_flag` = 报告**打印**的 ↑↓/H/L 原文（A 级来源事实）——原样落库，App 不计算、不解释、不据此提示（BR-004/012）。
    /// v27（子项目 J）：`healthExamId` = 体检一般检查投影回指 `metric_sample.health_exam_id`（参数缺省取 `sample.healthExamId`；
    /// 显式传入者优先——store 以 `ensureHealthExam` 返回 id 覆盖意图内的占位 id）；体检枢纽须存在且同成员（跨成员 → 整事务回滚）。
    static func insertHospitalSample(_ sample: HospitalSample, id: UUID, patientId: UUID,
                                     sourceRef: String, db: Database, now: Date,
                                     approvedCodingSystem: CodingSystem? = nil,
                                     labReportId: String? = nil,
                                     healthExamId: String? = nil) throws {
        try validateHospitalSample(sample)
        let examId = healthExamId ?? sample.healthExamId?.uuidString
        if let examId {
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_exam WHERE id = ? AND patient_id = ?",
                                   arguments: [examId, patientId.uuidString]) == 1 else { throw OCRCardStore.StoreError.invalidCard }
        }
        if let concept = sample.codeConceptId {
            guard let row = try Row.fetchOne(db, sql: "SELECT canonical_code, coding_system, kind FROM code_concept WHERE id = ?", arguments: [concept]),
                  (row["kind"] as String) == "metric", sample.metricKey == "code.\(row["canonical_code"] as String)",
                  approvedCodingSystem == nil || (row["coding_system"] as String) == approvedCodingSystem?.rawValue else {
                throw HealthImportStore.ImportError.invalidValue
            }
        } else if sample.metricKey.hasPrefix("code.") {
            throw HealthImportStore.ImportError.invalidValue
        }
        if let labReportId {
            // 成员隔离：表头必须存在且与样本同成员（跨成员表头 → 整事务回滚）。
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lab_report WHERE id = ? AND patient_id = ?",
                                   arguments: [labReportId, patientId.uuidString]) == 1 else { throw OCRCardStore.StoreError.invalidCard }
        }
        try db.execute(sql: """
            INSERT INTO metric_sample
              (id, patient_id, metric_key, value, unit, origin, self_measured, excluded,
               source_ref, ref_low, ref_high, ref_source_label, raw_label, code_concept_id, measured_at, created_at,
               lab_report_id, abnormal_flag, health_exam_id)
            VALUES (?, ?, ?, ?, ?, 'hospital', 0, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id.uuidString, patientId.uuidString, sample.metricKey, sample.value,
                              sample.unit, sourceRef, sample.refLow, sample.refHigh, sample.refSourceLabel,
                              sample.rawLabel, sample.codeConceptId, sample.measuredAt.timeIntervalSince1970,
                              now.timeIntervalSince1970, labReportId, OCRCardStore.normalized(sample.abnormalFlag), examId])
    }

    static func validateHospitalSample(_ sample: HospitalSample) throws {
        guard sample.value.isFinite, sample.measuredAt.timeIntervalSince1970.isFinite,
              !sample.metricKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sample.rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sample.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sample.refLow?.isFinite != false, sample.refHigh?.isFinite != false else {
            throw HealthImportStore.ImportError.invalidValue
        }
        if let low = sample.refLow, let high = sample.refHigh, low > high { throw HealthImportStore.ImportError.invalidValue }
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
        try await writer.write { db in
            try Self.upsertDeviceRows(rows, patientId: patientId, db: db)
        }
    }

    /// Shared by manual refresh and the atomic HealthKit checkpoint transaction.
    static func upsertDeviceRows(_ rows: [DeviceMetricRow], patientId: UUID, db: Database) throws -> Int {
        var changed = 0
        for row in rows {
            guard row.value.isFinite else { throw HealthImportStore.ImportError.invalidValue }
            let key = MetricType(grammarKey: row.metricKey)?.rawValue ?? row.metricKey
            var existingID: String?
            if let identity = row.sourceRef {
                existingID = try String.fetchOne(db, sql: """
                    SELECT id FROM metric_sample WHERE patient_id = ? AND origin = 'device'
                      AND source_ref = ? LIMIT 1
                    """, arguments: [patientId.uuidString, identity])
            }
            if existingID == nil {
                existingID = try String.fetchOne(db, sql: """
                    SELECT id FROM metric_sample WHERE patient_id = ? AND origin = 'device'
                      AND metric_key = ? AND measured_at = ? AND unit = ?
                      AND source_name IS ? AND source_ref IS NULL LIMIT 1
                    """, arguments: [patientId.uuidString, key, row.measuredAt.timeIntervalSince1970,
                                     row.unit, row.sourceName])
            }
            if let existingID {
                try db.execute(sql: """
                    UPDATE metric_sample SET value = ?, unit = ?, value_min = ?, value_max = ?, sample_count = ?,
                      source_name = ?, source_version = ?, source_product = ?, source_ref = ?,
                      source_identifier = ?, aggregation_kind = ?, window_end = ?
                    WHERE id = ? AND (value IS NOT ? OR unit IS NOT ? OR value_min IS NOT ? OR value_max IS NOT ?
                      OR sample_count IS NOT ? OR source_name IS NOT ? OR source_version IS NOT ?
                      OR source_product IS NOT ? OR source_ref IS NOT ? OR source_identifier IS NOT ?
                      OR aggregation_kind IS NOT ? OR window_end IS NOT ?)
                    """, arguments: [row.value, row.unit, row.valueMin, row.valueMax, row.sampleCount,
                        row.sourceName, row.sourceVersion, row.sourceProduct, row.sourceRef,
                        row.sourceIdentifier, row.aggregation?.rawValue, row.windowEnd?.timeIntervalSince1970,
                        existingID, row.value, row.unit, row.valueMin, row.valueMax, row.sampleCount,
                        row.sourceName, row.sourceVersion, row.sourceProduct, row.sourceRef,
                        row.sourceIdentifier, row.aggregation?.rawValue, row.windowEnd?.timeIntervalSince1970])
            } else {
                try db.execute(sql: """
                    INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin,
                      self_measured, excluded, value_min, value_max, sample_count,
                      source_name, source_version, source_product, source_ref, source_identifier,
                      aggregation_kind, window_end, measured_at, created_at)
                    VALUES (?, ?, ?, ?, ?, 'device', 1, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, patientId.uuidString, key, row.value, row.unit,
                        row.valueMin, row.valueMax, row.sampleCount, row.sourceName, row.sourceVersion,
                        row.sourceProduct, row.sourceRef, row.sourceIdentifier, row.aggregation?.rawValue,
                        row.windowEnd?.timeIntervalSince1970, row.measuredAt.timeIntervalSince1970,
                        Date().timeIntervalSince1970])
            }
            changed += db.changesCount
        }
        return changed
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
        public var sourceName: String?
        public var aggregation: MetricAggregation?
        public var windowEnd: Date?
        public var id: String { metricKey }
        public init(metricKey: String, value: Double, secondaryValue: Double? = nil,
                    unit: String?, origin: String, measuredAt: Date,
                    sourceName: String? = nil, aggregation: MetricAggregation? = nil, windowEnd: Date? = nil) {
            self.metricKey = metricKey
            self.value = value
            self.secondaryValue = secondaryValue
            self.unit = unit
            self.origin = origin
            self.measuredAt = measuredAt
            self.sourceName = sourceName; self.aggregation = aggregation; self.windowEnd = windowEnd
        }
    }

    /// SP-13 未连接空态判定（FR16.1 / ui-ux §5.45 V3.53）：成员名下是否
    /// 存在任何 origin='device' 读数。无设备读数 = 从未连接/未同步过
    /// Apple 健康——趋势详情空态分流为「未连接」+ 去连接深链，而非通用
    /// 无数据（有设备数据但该指标空 → 仍走通用空态）。
    /// 该指标在**任意时间窗**的最近一条读数时间（诊断性空态，2026-09-16 业主实测）：
    /// 7/30/90 天窗口可能为空（数据在更早），此前空态只给一句同步报告文案，
    /// 用户无从判断「是真的没有还是窗口没覆盖」——本查询给出「最近读数在哪」，
    /// 空态据此提示并可一键切到一年窗。
    /// 口径与 `series` 对齐：metric_key 匹配（血压舒张读收缩行 secondary_value 或
    /// 独立行）、excluded = 0；BR-001：设备来源仅本人可见（非本人按设备行不可见处理；
    /// 显式设备过滤而非本人 → 拒绝，与 series 同款）。
    public func latestMeasuredAt(patientId: UUID, metric: MetricType,
                                 origin: MetricOrigin?) async throws -> Date? {
        try await writer.read { db in
            let isSelf = try HealthImportStore.ownerPatient(db) == patientId
            if origin == .device, !isSelf { throw QueryError.deviceRequiresSelfBinding }
            // 键/值子句为白名单枚举字面量拼接（非用户输入，无注入面——与 series 同款）。
            let keyClause: String
            let valueClause: String
            if metric == .bloodPressureDia {
                keyClause = "(metric_key = 'bloodPressureDia' OR (metric_key = 'bloodPressureSys' AND secondary_value IS NOT NULL))"
                valueClause = "(value IS NOT NULL OR secondary_value IS NOT NULL)"
            } else {
                keyClause = "metric_key = '\(metric.rawValue)'"
                valueClause = "value IS NOT NULL"
            }
            let originClause: String
            var arguments: [DatabaseValueConvertible] = [patientId.uuidString]
            switch origin {
            case .some(let value):
                originClause = " AND origin = ?"
                arguments.append(value.rawValue)
            case nil:
                // 非本人成员的默认视图不含设备行（旧备份/重映射残留不得跨成员呈现）。
                originClause = isSelf ? "" : " AND origin != 'device'"
            }
            let value: Double? = try Double.fetchOne(db, sql: """
                SELECT MAX(measured_at) FROM metric_sample
                WHERE patient_id = ? AND \(keyClause) AND \(valueClause) AND excluded = 0\(originClause)
                """, arguments: StatementArguments(arguments))
            return value.map { Date(timeIntervalSince1970: $0) }
        }
    }

    /// F19 事实播报专用读取（FR17.1「最近血糖」）：只取最近 N 条**可见**读数。
    ///
    /// 为什么不是「定一个窗口再取尾 N 条」（旧实现）：那要先把窗口内全部行取回并
    /// 映射（1 年小时窗 ≈ 8760 行），再丢掉 99.9%——语音回读延迟压在用户等待上，
    /// 且「最近」被窗口绑死：读数早于窗口时播报「暂无记录」，窗口内的旧读数
    /// 又会被当作「最近」播报。本查询 `ORDER BY measured_at DESC LIMIT ?`
    /// 走 `idx_metric_patient_time`，一条语句、N 行，语义 = 该指标最近 N 条。
    /// 口径与 `series` 一致：excluded = 0、BR-001 非本人不计 device 行、
    /// 舒张压读收缩行 secondary_value 或独立行。
    public func latestPoints(patientId: UUID, metric: MetricType, limit: Int) async throws -> [TrendPoint] {
        guard limit > 0 else { return [] }
        return try await writer.read { db in
            let isSelf = try HealthImportStore.ownerPatient(db) == patientId
            let deviceClause = isSelf ? "" : " AND origin != 'device'"
            let (keyToQuery, valueColumn) = metric == .bloodPressureDia
                ? (MetricType.bloodPressureSys.rawValue, "secondary_value")
                : (metric.rawValue, "value")
            // 舒张压分支的参考范围必须**投影为 NULL**（与 series 的舒张压分支同款）：
            // 它读的是收缩压行的 secondary_value，行上的 ref_* 是**收缩压**的参考范围，
            // 跟着走会把收缩压区间挂到舒张压读数上（医学数值错标，BR-003 同族）。
            let refProjection = metric == .bloodPressureDia
                ? "NULL AS ref_low, NULL AS ref_high, NULL AS ref_source_label"
                : "ref_low, ref_high, ref_source_label"
            var points = try Row.fetchAll(db, sql: """
                SELECT id, metric_key, \(valueColumn) AS value, secondary_value, unit, origin, self_measured,
                       measured_at, excluded, source_ref, \(refProjection),
                       raw_label, code_concept_id, source_name, source_identifier,
                       aggregation_kind, window_end, value_min, value_max, sample_count
                FROM metric_sample
                WHERE patient_id = ? AND metric_key = ? AND \(valueColumn) IS NOT NULL
                  AND excluded = 0\(deviceClause)
                ORDER BY measured_at DESC LIMIT ?
                """, arguments: [patientId.uuidString, keyToQuery, limit]).map(Self.trendPoint)
            if metric == .bloodPressureDia {
                // 单值舒张压独立行（语音「低压 90」/自测单值）——与 series 同款并查，
                // 否则这类读数在播报路径上永远缺席
                points += try Row.fetchAll(db, sql: """
                    SELECT id, metric_key, value, secondary_value, unit, origin, self_measured,
                           measured_at, excluded, source_ref,
                           NULL AS ref_low, NULL AS ref_high, NULL AS ref_source_label,
                           raw_label, code_concept_id, source_name, source_identifier,
                           aggregation_kind, window_end, value_min, value_max, sample_count
                    FROM metric_sample
                    WHERE patient_id = ? AND metric_key = 'bloodPressureDia' AND value IS NOT NULL
                      AND excluded = 0\(deviceClause)
                    ORDER BY measured_at DESC LIMIT ?
                    """, arguments: [patientId.uuidString, limit]).map(Self.trendPoint)
            }
            // 并查后按时间倒序取前 N（两组各自最多 N 条，合并后再截断）
            return Array(points.sorted { $0.measuredAt > $1.measuredAt }.prefix(limit))
        }
    }

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
            // 第六轮修复保留：同刻并列取 rowid 最新，且每键**恰好一行**。
            // 2026-09-16 委员会评审改写：原「每行一次相关子查询」实测量级为
            // O(全部行×子查询)（12.7 万行实测 345 ms）；改窗口函数一次扫描——
            // `ROW_NUMBER() OVER (PARTITION BY metric_key ORDER BY measured_at DESC,
            // rowid DESC) = 1` 与原「每键取 (measured_at DESC, rowid DESC) 首行」
            // **逐字等价**（同排序键、同 tie-break），且 `idx_metric_latest`
            // 直接提供分区内排序。
            // BR-001（2026-09-16 第 1 项批修复）：非本人成员名下的 device 行不得呈现——
            // 宫格瓦片按 `origin == "device"` 打「设备」标（MetricTile），此前本查询
            // 没有 series/latestPoints 那条 origin 过滤，旧备份/重映射残留的 device 行
            // 会成为家属成员宫格上的「最新读数」。过滤放在窗口函数内：每键取到的是
            // **可见**行里最新的那条，与 series 的分流口径一致。
            let isSelf = try HealthImportStore.ownerPatient(db) == patientId
            let deviceClause = isSelf ? "" : " AND origin != 'device'"
            let rows = try Row.fetchAll(db, sql: """
                SELECT metric_key, value, secondary_value, unit, origin, measured_at,
                       source_name, aggregation_kind, window_end
                FROM (
                    SELECT metric_key, value, secondary_value, unit, origin, measured_at,
                           source_name, aggregation_kind, window_end,
                           ROW_NUMBER() OVER (PARTITION BY metric_key
                                              ORDER BY measured_at DESC, rowid DESC) AS rn
                    FROM metric_sample
                    WHERE patient_id = ? AND excluded = 0\(deviceClause)
                )
                WHERE rn = 1
                ORDER BY measured_at DESC
                """, arguments: [patientId.uuidString])
            return rows.map { row in
                LatestMetric(metricKey: row["metric_key"] as String,
                             value: row["value"] as Double,
                             secondaryValue: row["secondary_value"] as Double?,
                             unit: row["unit"] as String?,
                             origin: row["origin"] as String,
                             measuredAt: Date(timeIntervalSince1970: row["measured_at"] as Double),
                             sourceName: row["source_name"] as String?,
                             aggregation: (row["aggregation_kind"] as String?).flatMap(MetricAggregation.init(rawValue:)),
                             windowEnd: (row["window_end"] as Double?).map(Date.init(timeIntervalSince1970:)))
            }
        }
    }
}
#endif
