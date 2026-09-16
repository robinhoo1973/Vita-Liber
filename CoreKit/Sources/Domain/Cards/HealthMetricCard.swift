// P9 信封储备（2026-09-16 委员会评审核实 + 业主裁定保留）：
// 本类型是 `InformationCard` 协议族的一员，**当前零生产引用**（仅测试维持；
// 生产落库形状是 `MatchedCard` + `FieldDraft` + 各 Store 行类型）。保留理由：
// 纯值类型、零框架依赖、承载 P9 溯源字段（rawText/source/confidence），
// 作为新卡类模块（如 `HealthMetricCard`——协议族唯一在用者）的现成信封形态。
// 新增卡类优先复用本族协议，勿另起第二套。勿按「无引用」当死代码清理。

import Foundation

/// Apple 健康信息卡（swift-class-design.md §4.4 卡清单 + F16 落地，结构轮 2026-09-15）：
/// 单条设备读数窗口的 `InformationCard` 信封。与医院体检（`HealthExam` 实体 /
/// `health_exam` 表）不同域：本卡 `cardType = "health_metric"`，持久化事实行仍是
/// `metric_sample`（origin='device'）——卡为**读侧装配**，不建第二存储（避免双写漂移）。
///
/// P9 溯源偏差说明（刻意，仅限机器测量数据）：HealthKit 无原始文本，`rawText` 恒 nil；
/// 溯源性由 `sampleRef`（窗口身份前缀）+ 来源三键（sourceName/sourceVersion/sourceProduct）
/// 承担。`source = .healthKit`；`confidence = 1.0`（机器测量不经 OCR 推断）。
public struct HealthMetricCard: InformationCard {
    public static let cardType = "health_metric"

    public var cardId: String
    public var patientId: String?
    public var source: DataSource = .healthKit
    public var confidence: Double = 1.0
    public var fieldConfidence: [String: Double] = [:]
    public var rawText: String? = nil
    public var createdAt: Date
    public var updatedAt: Date

    // 业务字段（metric_sample 设备行的 Domain 投影）
    public var kind: HealthDataKind
    public var metricKey: String
    public var value: Double
    public var unit: String
    public var valueMin: Double?
    public var valueMax: Double?
    public var sampleCount: Int?
    public var aggregation: MetricAggregation?
    public var measuredAt: Date
    public var windowEnd: Date?
    /// 窗口身份前缀回链（`metric_sample.source_ref`）——P9 溯源在无 rawText 时的替代物
    public var sampleRef: String?
    public var sourceName: String?
    public var sourceVersion: String?
    public var sourceProduct: String?
    public var sourceIdentifier: String?
    /// 后处理槽位（`HealthCardComposer` 填充）：B 级信源参考范围（正常带 = l1 界限内）
    public var referenceRange: ReferenceRange?
    /// 引用式提示级别（`AlertRuleEngine` 定级；仅呈现，非诊断——BR-006）
    public var severity: AlertSeverity?

    public init(cardId: String, patientId: UUID?, kind: HealthDataKind, metricKey: String,
                value: Double, unit: String, measuredAt: Date,
                valueMin: Double? = nil, valueMax: Double? = nil, sampleCount: Int? = nil,
                aggregation: MetricAggregation? = nil, windowEnd: Date? = nil,
                sampleRef: String? = nil, sourceName: String? = nil, sourceVersion: String? = nil,
                sourceProduct: String? = nil, sourceIdentifier: String? = nil,
                referenceRange: ReferenceRange? = nil, severity: AlertSeverity? = nil) {
        self.cardId = cardId
        self.patientId = patientId.map(\.uuidString)
        self.kind = kind
        self.metricKey = metricKey
        self.value = value
        self.unit = unit
        self.measuredAt = measuredAt
        self.valueMin = valueMin
        self.valueMax = valueMax
        self.sampleCount = sampleCount
        self.aggregation = aggregation
        self.windowEnd = windowEnd
        self.sampleRef = sampleRef
        self.sourceName = sourceName
        self.sourceVersion = sourceVersion
        self.sourceProduct = sourceProduct
        self.sourceIdentifier = sourceIdentifier
        self.referenceRange = referenceRange
        self.severity = severity
        self.createdAt = measuredAt
        self.updatedAt = measuredAt
    }

    /// 读侧装配（纯函数）：`DeviceMetricRow` → 卡；持久化事实行不动。
    public static func make(from row: DeviceMetricRow, kind: HealthDataKind, patientId: UUID?) -> HealthMetricCard {
        HealthMetricCard(
            cardId: row.sourceRef ?? "hk:\(kind.rawValue):\(UUID().uuidString)",
            patientId: patientId,
            kind: kind,
            metricKey: row.metricKey,
            value: row.value,
            unit: row.unit,
            measuredAt: row.measuredAt,
            valueMin: row.valueMin,
            valueMax: row.valueMax,
            sampleCount: row.sampleCount,
            aggregation: row.aggregation,
            windowEnd: row.windowEnd,
            sampleRef: row.sourceRef,
            sourceName: row.sourceName,
            sourceVersion: row.sourceVersion,
            sourceProduct: row.sourceProduct,
            sourceIdentifier: row.sourceIdentifier)
    }
}
