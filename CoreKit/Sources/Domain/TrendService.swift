import Foundation

/// F7 指标趋势语义（§5.29）：值类型投影 + 双来源空心/实心 + 换算留痕 + 软删排除。
/// 渲染选型 = Swift Charts（ADR-022）；本层只负责查询语义，UI 层做图表。
public enum MetricType: String, Sendable, Equatable, Codable, CaseIterable {
    case bloodPressureSys, bloodPressureDia, glucose, weight, heartRate, bloodOxygen

    /// 语音文法键（snake_case，VoiceGrammarDefaults.metricRules 单一事实源）→ 指标类型。
    /// 语音确认卡与语音会话共用同一映射——键词汇只存在这一处
    /// （此前视图层各写一份第三份拷贝，键漂移即静默错落指标）。
    public init?(grammarKey: String) {
        switch grammarKey {
        case "blood_pressure_sys": self = .bloodPressureSys
        case "blood_pressure_dia": self = .bloodPressureDia
        case "glucose": self = .glucose
        case "heart_rate": self = .heartRate
        case "weight": self = .weight
        case "blood_oxygen": self = .bloodOxygen
        default: return nil
        }
    }
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
    /// 报告自带参考范围（A 级）与其来源标签。FR7.2：同图多医院时**各自成带**。
    public var refLow: Double?
    public var refHigh: Double?
    public var refSourceLabel: String?   // 医院/实验室名 = 分组键
    public init(id: UUID, measuredAt: Date, value: Double, unit: String? = nil,
                origin: MetricOrigin, excluded: Bool = false, sourceRef: String? = nil,
                refLow: Double? = nil, refHigh: Double? = nil, refSourceLabel: String? = nil) {
        self.id = id; self.measuredAt = measuredAt; self.value = value
        self.unit = unit; self.origin = origin; self.excluded = excluded; self.sourceRef = sourceRef
        self.refLow = refLow; self.refHigh = refHigh; self.refSourceLabel = refSourceLabel
    }
    /// 空心=自测/设备；实心=医院报告（ui-ux 4.7 一眼可辨）
    public var isHollow: Bool { origin != .hospital }
}

/// FR7.2 的类型化表达：一条**独立**参考带 = 一个来源 + 一个区间。
/// 用数组承载多带，使「合并成一条正常带」在类型层面就无处可写——
/// 旧模型 `referenceRange: ReferenceRange?` 是单数，把「多来源并存」这个
/// 合法状态直接表达掉了，规则再正确也无处落脚（本次 5WHY 的根因）。
public struct ReferenceBand: Sendable, Equatable, Identifiable {
    public var sourceLabel: String       // 医院/实验室名；B 级为信源库条目名
    public var lower: Double
    public var upper: Double
    public var grade: ReferenceRange.Grade
    public var id: String { "\(grade.rawValue)|\(sourceLabel)|\(lower)|\(upper)" }
    public init(sourceLabel: String, lower: Double, upper: Double, grade: ReferenceRange.Grade) {
        self.sourceLabel = sourceLabel; self.lower = lower; self.upper = upper; self.grade = grade
    }
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
    /// FR7.2：多来源参考带并存，**各自独立**。空数组 = 范围不可用（独立渲染状态，
    /// 不显示通用范围——§5.29「范围是否可用作为独立渲染状态」）。
    public var referenceBands: [ReferenceBand]
    /// 对照视图用：被排除的点（软删，保留原值可恢复，FR7.4）。
    /// 与 `points` 分离而不是塞进同一数组加标志位——避免任何聚合/统计路径
    /// 忘记过滤 excluded 而把排除点算进去。
    public var excludedPoints: [TrendPoint]
    public init(metricType: MetricType, points: [TrendPoint],
                referenceBands: [ReferenceBand] = [], excludedPoints: [TrendPoint] = []) {
        self.metricType = metricType; self.points = points
        self.referenceBands = referenceBands; self.excludedPoints = excludedPoints
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

    /// **FR7.2 铁律（一票否决）：不同医院的参考范围不得合并成一条正常带。**
    ///
    /// 从点集提取 A 级参考带：按 (来源标签, 下限, 上限) 去重，**不做任何跨来源的
    /// 取交集/取并集/取平均**——三家医院即三条带，哪怕区间数值恰好相同也按来源分开
    /// （来源是分组键，不是可省略的装饰；合并会让用户误以为存在统一"正常值"）。
    ///
    /// 优先级（FR16.4）：只要存在 A 级带，就**不**混入 B 级信源库缺省带——
    /// A/B 混排等价于用 B 级替代医院原文，是 FR16.4 明令禁止的。
    /// 无任何 A 级带时才回落 B 级；两者皆无返回空数组（= 范围不可用）。
    public static func resolveBands(points: [TrendPoint],
                                    libraryFallback: ReferenceBand? = nil) -> [ReferenceBand] {
        var seen = Set<String>()
        var bands: [ReferenceBand] = []
        for p in points {
            guard let lo = p.refLow, let hi = p.refHigh else { continue }
            // 来源标签缺失时不臆造：按「未标注来源」独立成带，仍不与他人合并
            let label = p.refSourceLabel?.trimmingCharacters(in: .whitespaces)
            let source = (label?.isEmpty == false) ? label! : "未标注来源"
            let band = ReferenceBand(sourceLabel: source, lower: lo, upper: hi, grade: .A)
            if seen.insert(band.id).inserted { bands.append(band) }
        }
        if bands.isEmpty, let fallback = libraryFallback, fallback.grade == .B {
            return [fallback]
        }
        // 稳定输出：按来源名排序，保证渲染顺序与图例顺序一致、快照可复现
        return bands.sorted { $0.sourceLabel < $1.sourceLabel }
    }

    /// 换算留痕：换算只发生在查询层，原值不动；换算后渲染「换算自 xx」
    ///
    /// **参考带必须同步换算**：只换点不换带会把 mmol/L 的读数摆在 mg/dL 的
    /// 参考带上，视觉上直接读出错误的「超标/正常」——这是 BR-006「不作判断」
    /// 之外更硬的正确性问题（旧实现只映射了 points，本次一并修正）。
    /// 排除点同样换算，否则对照视图里两组点不同量纲。
    public static func converted(_ series: TrendSeries, using conversion: UnitConversion) -> TrendSeries {
        func convert(_ p: TrendPoint) -> TrendPoint {
            var q = p
            q.value = conversion.convert(p.value)
            q.unit = conversion.toUnit
            if let lo = p.refLow { q.refLow = conversion.convert(lo) }
            if let hi = p.refHigh { q.refHigh = conversion.convert(hi) }
            return q
        }
        var s = series
        s.points = series.points.map(convert)
        s.excludedPoints = series.excludedPoints.map(convert)
        s.referenceBands = series.referenceBands.map { band in
            ReferenceBand(sourceLabel: band.sourceLabel,
                          lower: conversion.convert(band.lower),
                          upper: conversion.convert(band.upper),
                          grade: band.grade)
        }
        return s
    }

    /// 稳定排序（时间升序）
    public static func sorted(_ points: [TrendPoint]) -> [TrendPoint] {
        points.sorted { $0.measuredAt < $1.measuredAt }
    }
}
