import Foundation

/// F16 Apple 健康导入的表现层读模型（结构轮 2026-09-15：自
/// Infrastructure/HealthImportStore+Presentation.swift 迁入）。
/// 纯值形状（P4）归 Domain——此前嵌套在 GRDB actor 内，UI 依赖
/// Infrastructure 内部类型、且 Dashboard 反向依赖同步服务的 SyncReport；
/// 迁移后读模型可在 Domain 层单测（P7），存储侧只留 SQL。
public struct HealthTypeSummary: Sendable, Identifiable {
    public let kind: HealthDataKind
    public let rowCount: Int
    public let latestAt: Date?
    public var id: HealthDataKind { kind }
    public init(kind: HealthDataKind, rowCount: Int, latestAt: Date?) {
        self.kind = kind; self.rowCount = rowCount; self.latestAt = latestAt
    }
}

public struct HealthImportDashboard: Sendable {
    public let patientId: UUID
    public let ownerName: String
    public let connected: Bool
    public let bindingId: UUID?
    public let types: [HealthTypeSummary]
    public let lastReport: SyncReport?
    public init(patientId: UUID, ownerName: String, connected: Bool, bindingId: UUID?,
                types: [HealthTypeSummary], lastReport: SyncReport?) {
        self.patientId = patientId; self.ownerName = ownerName; self.connected = connected
        self.bindingId = bindingId; self.types = types; self.lastReport = lastReport
    }
}

public struct HealthImportRow: Sendable, Identifiable {
    public let id: UUID
    public let patientId: UUID
    public let metricKey: String
    public let value: Double
    public let unit: String
    public let measuredAt: Date
    public let sourceName: String?
    /// FR7.9 统计事实（2026-09-15 实测修复）：设备行不是「一次测量」——心率按小时均值、
    /// 步数按日累计、睡眠按时段时长。此前读模型丢掉这五列，SP-29 记录列表把日累计步数
    /// 显示成单条读数（同一数据在 SP-13 趋势页却标着「每日累计」）。列由导入侧写入
    /// （`writeProjection`），此处只是投影出来。
    public let aggregation: MetricAggregation?
    public let windowEnd: Date?
    public let valueMin: Double?
    public let valueMax: Double?
    public let sampleCount: Int?
    public init(id: UUID, patientId: UUID, metricKey: String, value: Double, unit: String,
                measuredAt: Date, sourceName: String?,
                aggregation: MetricAggregation? = nil, windowEnd: Date? = nil,
                valueMin: Double? = nil, valueMax: Double? = nil, sampleCount: Int? = nil) {
        self.id = id; self.patientId = patientId; self.metricKey = metricKey; self.value = value
        self.unit = unit; self.measuredAt = measuredAt; self.sourceName = sourceName
        self.aggregation = aggregation; self.windowEnd = windowEnd
        self.valueMin = valueMin; self.valueMax = valueMax; self.sampleCount = sampleCount
    }
}
