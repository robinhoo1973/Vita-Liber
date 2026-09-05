import Foundation

/// F16 四级观察提示（L0-L3，§5.12）：规则预警引擎——纯函数，零网络。
/// 医学数字单一事实源：阈值统一取自 GuidelineSource（B 级），
/// 报告自带参考范围（A 级）优先；任何模块不得私设第二套医学数值。
public enum AlertSeverity: String, Sendable, Equatable, Codable, CaseIterable {
    case L0, L1, L2, L3
}

/// 信源条目（FR16.4：仅国家级学会指南/政府卫生机构/WHO/AHA/ESC；
/// 阈值数字照抄原文禁止改写；带版本号/条目引用/链接检查日期）
public struct GuidelineEntry: Sendable, Equatable, Codable {
    public var id: UUID
    public var title: String
    public var org: String
    public var year: Int
    public var clauseRef: String
    public var citationUrl: String
    public var version: String
    public var checkedAt: Date
    public var metricKey: String
    public var l1Low: Double?
    public var l1High: Double?
    public var l2Low: Double?
    public var l2High: Double?
    public var l3Low: Double?
    public var l3High: Double?
    public var unit: String
    public init(id: UUID = UUID(), title: String, org: String, year: Int,
                clauseRef: String, citationUrl: String, version: String,
                checkedAt: Date, metricKey: String, unit: String,
                l1Low: Double? = nil, l1High: Double? = nil,
                l2Low: Double? = nil, l2High: Double? = nil,
                l3Low: Double? = nil, l3High: Double? = nil) {
        self.id = id; self.title = title; self.org = org; self.year = year
        self.clauseRef = clauseRef; self.citationUrl = citationUrl; self.version = version
        self.checkedAt = checkedAt; self.metricKey = metricKey; self.unit = unit
        self.l1Low = l1Low; self.l1High = l1High
        self.l2Low = l2Low; self.l2High = l2High
        self.l3Low = l3Low; self.l3High = l3High
    }
}

public struct MetricReading: Sendable, Equatable {
    public var metricKey: String
    public var value: Double
    public var unit: String
    public var origin: MetricOrigin
    public var measuredAt: Date
    public var reportRange: ReferenceRange?    // A 级（报告自带）优先
    public init(metricKey: String, value: Double, unit: String, origin: MetricOrigin,
                measuredAt: Date, reportRange: ReferenceRange? = nil) {
        self.metricKey = metricKey; self.value = value; self.unit = unit
        self.origin = origin; self.measuredAt = measuredAt; self.reportRange = reportRange
    }
}

/// 五段证据卡（§5.12/FR16.2）：事实 → 阈值来源链接 → 建议路径 → 固定免责 → 级别标签
/// 证据卡建议路径（FR16.3 五段之三）：引用式提示，非诊断；App 层经 L10n 渲染
public enum EvidencePath: String, Sendable, Equatable, Codable {
    case retestNow      // L3：立即复测
    case scheduleVisit  // L2：近期复测并携带记录就诊
    case observe        // L0/L1：继续观察记录
}

public struct AlertEvidenceCard: Sendable, Equatable, Codable {
    public var severity: AlertSeverity
    public var levelTag: String            // L1/L2/L3
    /// V3.68 结构化字段：事实读数/信源书目/建议路径均为类型化数据，
    /// 视图层经 L10n 渲染（zh-Hant/en 用户不再看到简体句式——
    /// §11「Domain 文案硬编码」清偿项）。
    public var metricKey: String?
    public var value: Double?
    public var unit: String?
    public var origin: String?
    public var measuredAt: Date?
    public var sourceTitle: String?
    public var sourceOrg: String?
    public var sourceYear: Int?
    public var sourceClause: String?
    public var path: EvidencePath?
    /// 旧行兼容：历史 evidence JSON 按旧字段直出展示（decodeIfPresent，
    /// 不重排不丢数据）。
    public var legacyFacts: String?
    public var legacySourceRef: String?
    public var legacyPath: String?
    public var legacyDisclaimer: String?
    public init(severity: AlertSeverity, levelTag: String? = nil,
                metricKey: String? = nil, value: Double? = nil, unit: String? = nil,
                origin: String? = nil, measuredAt: Date? = nil,
                sourceTitle: String? = nil, sourceOrg: String? = nil,
                sourceYear: Int? = nil, sourceClause: String? = nil,
                path: EvidencePath? = nil,
                legacyFacts: String? = nil, legacySourceRef: String? = nil,
                legacyPath: String? = nil, legacyDisclaimer: String? = nil) {
        self.severity = severity
        self.levelTag = levelTag ?? severity.rawValue
        self.metricKey = metricKey; self.value = value; self.unit = unit
        self.origin = origin; self.measuredAt = measuredAt
        self.sourceTitle = sourceTitle; self.sourceOrg = sourceOrg
        self.sourceYear = sourceYear; self.sourceClause = sourceClause
        self.path = path
        self.legacyFacts = legacyFacts; self.legacySourceRef = legacySourceRef
        self.legacyPath = legacyPath; self.legacyDisclaimer = legacyDisclaimer
    }
}

/// 措辞负清单（FR16.5 一票否决）：禁止疾病名推断/因果句/治疗建议句式
public enum WordingBlacklist {
    static let patterns: [(String, String)] = [
        ("可能是(.+?)病", "疾病名推断"),
        ("可能是(.+?)症", "疾病名推断"),
        ("因为(.+?)所以", "因果句式"),
        ("建议服用", "治疗建议"),
        ("应该吃药", "治疗建议"),
        ("确诊", "诊断表述"),
        ("治疗(.+?)即可", "治疗建议"),
    ]
    public static func violation(in text: String) -> String? {
        for (pattern, label) in patterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return "\(label)：\(pattern)"
            }
        }
        return nil
    }
}

/// 规则引擎（纯函数，可单测）：连续 3 次越限触发 L1（FR16.2 验收）
public enum AlertRuleEngine {
    public static let consecutiveThreshold = 3

    /// 单次读数定级：报告自带 A 级范围优先（FR16.4 铁律）；
    /// 无报告范围 → 信源库 B 级；无信源 → 不定级（范围不可用独立状态）
    public static func severity(for reading: MetricReading, guideline: GuidelineEntry?) -> AlertSeverity? {
        // A 级优先：报告自带参考范围
        if let report = reading.reportRange, report.grade == .A {
            if reading.value > report.upper || reading.value < report.lower {
                return .L1   // 报告范围越限 = 事实呈现，级别 L1（无 B 级阈值时不升级）
            }
            return .L0
        }
        guard let g = guideline else { return nil }   // 无信源 = 范围不可用
        if let high = g.l3High, reading.value >= high { return .L3 }
        if let low = g.l3Low, reading.value <= low { return .L3 }
        if let high = g.l2High, reading.value >= high { return .L2 }
        if let low = g.l2Low, reading.value <= low { return .L2 }
        if let high = g.l1High, reading.value >= high { return .L1 }
        if let low = g.l1Low, reading.value <= low { return .L1 }
        return .L0
    }

    /// 连续 3 次越限 → 至少 L1（FR16.2 验收句）
    public static func escalate(recent: [MetricReading], guideline: GuidelineEntry?) -> AlertSeverity? {
        let levels = recent.compactMap { severity(for: $0, guideline: guideline) }
        guard levels.count >= consecutiveThreshold else { return nil }
        let last = recent.suffix(consecutiveThreshold)
        let lastLevels = last.compactMap { severity(for: $0, guideline: guideline) }
        let allBeyondL0 = lastLevels.allSatisfy { $0 != .L0 }
        guard allBeyondL0 else { return nil }
        return lastLevels.max { a, b in
            AlertSeverity.allCases.firstIndex(of: a)! < AlertSeverity.allCases.firstIndex(of: b)!
        }
    }

    /// 五段证据卡组装（引用式提示，禁止生成式解读——ADR-010）
    public static func evidenceCard(for reading: MetricReading, severity: AlertSeverity,
                                    guideline: GuidelineEntry?) -> AlertEvidenceCard {
        let path: EvidencePath
        switch severity {
        case .L3: path = .retestNow
        case .L2: path = .scheduleVisit
        default: path = .observe
        }
        // V3.68：结构化输出——事实/信源/建议路径均为类型化数据，
        // 中文句式由视图层经 L10n 组装（§11 Domain 文案硬编码清偿）。
        // 免责为固定语义（无文案）：视图层渲染 L10n 固定免责键。
        return AlertEvidenceCard(
            severity: severity,
            metricKey: reading.metricKey,
            value: reading.value,
            unit: reading.unit,
            origin: reading.origin.rawValue,
            measuredAt: reading.measuredAt,
            sourceTitle: guideline?.title,
            sourceOrg: guideline?.org,
            sourceYear: guideline?.year,
            sourceClause: guideline?.clauseRef,
            path: path)
    }
}
