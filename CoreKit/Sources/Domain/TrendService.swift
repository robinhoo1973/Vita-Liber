import Foundation

/// F7 指标趋势语义（§5.29）：值类型投影 + 双来源空心/实心 + 换算留痕 + 软删排除。
/// 渲染选型 = Swift Charts（ADR-022）；本层只负责查询语义，UI 层做图表。
public enum MetricType: String, Sendable, Equatable, Codable, CaseIterable {
    case bloodPressureSys, bloodPressureDia, glucose, weight, heartRate, bloodOxygen
}

public enum MetricOrigin: String, Sendable, Equatable, Codable {
    case hospital, manual, device
}

public struct TrendPoint: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var measuredAt: Date
    public var value: Double
    public var unit: String?
    public var origin: MetricOrigin
    public var excluded: Bool
    public var sourceRef: String?        // 回原报告（点击点 → document_file/encounter 引用）
    public init(id: UUID, measuredAt: Date, value: Double, unit: String? = nil,
                origin: MetricOrigin, excluded: Bool = false, sourceRef: String? = nil) {
        self.id = id; self.measuredAt = measuredAt; self.value = value
        self.unit = unit; self.origin = origin; self.excluded = excluded; self.sourceRef = sourceRef
    }
    /// 空心=自测/设备；实心=医院报告（ui-ux 4.7 一眼可辨）
    public var isHollow: Bool { origin != .hospital }
}

public struct ReferenceRange: Sendable, Equatable {
    public enum Grade: String, Sendable, Equatable { case A, B }   // A=报告自带 > B=信源库
    public var lower: Double
    public var upper: Double
    public var grade: Grade
    public var sourceNote: String?
    public init(lower: Double, upper: Double, grade: Grade, sourceNote: String? = nil) {
        self.lower = lower; self.upper = upper; self.grade = grade; self.sourceNote = sourceNote
    }
}

public struct TrendSeries: Sendable, Equatable {
    public var metricType: MetricType
    public var points: [TrendPoint]
    public var referenceRange: ReferenceRange?
    public init(metricType: MetricType, points: [TrendPoint], referenceRange: ReferenceRange? = nil) {
        self.metricType = metricType; self.points = points; self.referenceRange = referenceRange
    }
}

/// 单位换算留痕（§5.29）：表内存原值+原始单位，换算只在查询/渲染层，绝不覆盖原值
public struct UnitConversion: Sendable, Equatable {
    public var fromUnit: String
    public var toUnit: String
    public var factor: Double          // value * factor = converted
    public var note: String            // 「换算自 xx」小注
    public init(fromUnit: String, toUnit: String, factor: Double, note: String) {
        self.fromUnit = fromUnit; self.toUnit = toUnit; self.factor = factor; self.note = note
    }
    public func convert(_ value: Double) -> Double { value * factor }
}

public enum TrendRules {
    /// 软删排除（§5.29）：聚合默认 WHERE excluded=0；对照视图显示已排除点（保留原值可恢复）
    public static func visible(_ points: [TrendPoint]) -> [TrendPoint] {
        points.filter { !$0.excluded }
    }

    /// 参考范围优先级铁律（FR16.4）：A 级（报告自带）> B 级（信源库）；
    /// 无 A 级且无信源库可用时 = 范围不可用（独立渲染状态，不显示通用范围）
    public static func resolveRange(reportRange: ReferenceRange?, libraryRange: ReferenceRange?) -> ReferenceRange? {
        if let report = reportRange, report.grade == .A { return report }
        if let lib = libraryRange, lib.grade == .B { return lib }
        return nil
    }

    /// 换算留痕：换算只发生在查询层，原值不动；换算后渲染「换算自 xx」
    public static func converted(_ series: TrendSeries, using conversion: UnitConversion) -> TrendSeries {
        var s = series
        s.points = series.points.map { p in
            var q = p
            q.value = conversion.convert(p.value)
            return q
        }
        return s
    }

    /// 稳定排序（时间升序）
    public static func sorted(_ points: [TrendPoint]) -> [TrendPoint] {
        points.sorted { $0.measuredAt < $1.measuredAt }
    }
}
