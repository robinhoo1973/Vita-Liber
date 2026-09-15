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
    public init(id: UUID, patientId: UUID, metricKey: String, value: Double, unit: String,
                measuredAt: Date, sourceName: String?) {
        self.id = id; self.patientId = patientId; self.metricKey = metricKey; self.value = value
        self.unit = unit; self.measuredAt = measuredAt; self.sourceName = sourceName
    }
}
