import Foundation

/// F7 指标趋势语义（§5.29）：值类型投影 + 双来源空心/实心 + 换算留痕 + 软删排除。
/// 渲染选型 = Swift Charts（ADR-022）；本层只负责查询语义，UI 层做图表。
/// 结构轮（2026-09-15）：自 TrendService.swift 拆分——原文件名与内容不符
/// （9 个公开类型、并无 `TrendService`），模型与规则各自成文件（P2/0.3 命名）。
public enum MetricType: String, Sendable, Equatable, Codable, CaseIterable {
    case bloodPressureSys, bloodPressureDia, glucose, weight, temperature, heartRate, bloodOxygen
    case restingHeartRate
    case respiratoryRate = "respiratory_rate"
    case steps
    case sleepTotal = "sleep_total", sleepDeep = "sleep_deep", sleepREM = "sleep_rem"
    case sleepAwake = "sleep_awake", sleepCore = "sleep_core", sleepUnspecified = "sleep_unspecified"

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
        case "temperature": self = .temperature
        default:
            guard let known = Self(rawValue: grammarKey) else { return nil }
            self = known
        }
    }
}

public enum MetricOrigin: String, Sendable, Equatable, Codable {
    case hospital, manual, device
}

/// F7.5 血压双值录入 UI 规则（Domain 纯函数——业务边界不在视图内联）：
/// 两位/三位数输完自动跳格的合理性边界（≥60 mmHg 视为真实收缩压值，
/// 90-99 常见于低血压/老年用户；此前视图硬编码 60 且不可单测）
public enum BloodPressureEntryRules {
    /// 构成真实收缩压值的最小界限（mmHg）
    public static let minPlausibleSys: Double = 60
}

/// 手录/语音录入指标的合理性界限（审查修复 2026-09-18）：界外值拒绝落库——
/// 手滑/口误的「血压 800」此前以 C 级样本持久化并污染趋势与告警证据链
/// （仅 >0 与 NaN/inf 守卫）。界限取宽松生理边界：宁可拒绝极罕见的极端
/// 真值（可走趋势页备注通道），也不放过明显误录；缺失键回落放行（不臆造边界）。
public enum MetricEntryRules {
    /// 指标 → 宽松合理性范围（数值超出即拒绝）。
    public static func plausibleBounds(for metric: MetricType) -> ClosedRange<Double>? {
        switch metric {
        case .bloodPressureSys: return 60...280        // mmHg
        case .bloodPressureDia: return 30...180        // mmHg
        case .glucose: return 1...60                   // mmol/L
        case .heartRate, .restingHeartRate: return 20...250
        case .bloodOxygen: return 40...100             // %
        case .temperature: return 30...45              // ℃
        case .weight: return 2...500                   // kg
        case .respiratoryRate, .steps,
             .sleepTotal, .sleepDeep, .sleepREM, .sleepAwake, .sleepCore, .sleepUnspecified:
            return nil                                 // 设备源/聚合指标不设手录边界
        }
    }

    /// 界内放行；无边界键放行（不臆造）；界外拒绝。
    public static func isPlausible(_ value: Double, for metric: MetricType) -> Bool {
        guard let range = plausibleBounds(for: metric) else { return true }
        return range.contains(value)
    }
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
    /// F25（V3.72）：原始指标名与规范编码投影——读侧聚合键
    /// code_concept_id 优先、无编码回落 metric_key（FR25.12⑦/§5.29）。
    /// 未确认行 code_concept_id 为空（BR-003，确认前不落编码）。
    public var rawLabel: String?
    public var codeConceptId: String?
    public var sourceName: String?
    public var sourceIdentifier: String?
    public var aggregation: MetricAggregation?
    public var windowEnd: Date?
    public var valueMin: Double?
    public var valueMax: Double?
    public var sampleCount: Int?
    public init(id: UUID, measuredAt: Date, value: Double, unit: String? = nil,
                origin: MetricOrigin, excluded: Bool = false, sourceRef: String? = nil,
                refLow: Double? = nil, refHigh: Double? = nil, refSourceLabel: String? = nil,
                rawLabel: String? = nil, codeConceptId: String? = nil,
                sourceName: String? = nil, sourceIdentifier: String? = nil,
                aggregation: MetricAggregation? = nil, windowEnd: Date? = nil,
                valueMin: Double? = nil, valueMax: Double? = nil, sampleCount: Int? = nil) {
        self.id = id; self.measuredAt = measuredAt; self.value = value
        self.unit = unit; self.origin = origin; self.excluded = excluded; self.sourceRef = sourceRef
        self.refLow = refLow; self.refHigh = refHigh; self.refSourceLabel = refSourceLabel
        self.rawLabel = rawLabel; self.codeConceptId = codeConceptId
        self.sourceName = sourceName; self.sourceIdentifier = sourceIdentifier
        self.aggregation = aggregation; self.windowEnd = windowEnd
        self.valueMin = valueMin; self.valueMax = valueMax; self.sampleCount = sampleCount
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

public struct ReferenceRange: Sendable, Equatable, Codable {
    public enum Grade: String, Sendable, Equatable, Codable { case A, B }   // A=报告自带 > B=信源库
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
    /// round2 H2：查询身份回传——渲染层用 `series.identity == 请求身份` 丢弃过期/错位结果；
    /// nil = 未携身份的旧路径（兼容包装 / Domain 内部构造）。
    public var identity: TrendQueryIdentity?
    public init(metricType: MetricType, points: [TrendPoint],
                referenceBands: [ReferenceBand] = [], excludedPoints: [TrendPoint] = [],
                identity: TrendQueryIdentity? = nil) {
        self.metricType = metricType; self.points = points
        self.referenceBands = referenceBands; self.excludedPoints = excludedPoints
        self.identity = identity
    }
}

/// 单位换算留痕（§5.29）：表内存原值+原始单位，换算只在查询/渲染层，绝不覆盖原值
public struct UnitConversion: Sendable, Equatable {
    public var fromUnit: String
    public var toUnit: String
    public var factor: Double          // value * factor + offset = converted
    public var offset: Double          // V3.69/F25：仿射换算（℃/℉ 族）；默认 0 保持既有线性语义
    public var note: String            // 「换算自 xx」小注
    public init(fromUnit: String, toUnit: String, factor: Double, offset: Double = 0, note: String) {
        self.fromUnit = fromUnit; self.toUnit = toUnit; self.factor = factor
        self.offset = offset; self.note = note
    }
    public func convert(_ value: Double) -> Double { value * factor + offset }
}
