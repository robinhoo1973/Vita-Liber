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
    // V3.86/迁移 v18：设备来源元数据（HKSource 三键，幂等键含来源；
    // 手输/医院行为 nil）
    public var sourceName: String?
    public var sourceVersion: String?
    public var sourceProduct: String?
    public var sourceIdentifier: String?
    public var sampleID: String?
    public init(metricKey: String, value: Double, unit: String, origin: MetricOrigin,
                measuredAt: Date, reportRange: ReferenceRange? = nil,
                sourceName: String? = nil, sourceVersion: String? = nil,
                 sourceProduct: String? = nil, sourceIdentifier: String? = nil,
                 sampleID: String? = nil) {
        self.metricKey = metricKey; self.value = value; self.unit = unit
        self.origin = origin; self.measuredAt = measuredAt; self.reportRange = reportRange
        self.sourceName = sourceName
        self.sourceVersion = sourceVersion
        self.sourceProduct = sourceProduct
        self.sourceIdentifier = sourceIdentifier
        self.sampleID = sampleID
    }
}

/// FR7.9 设备读数落库行（小时窗口聚合后；metric_sample 六列的 Domain 形态）。
/// 评估与入库双流（V3.86）：分钟级原始读数内存态评估 → alert_event；
/// 聚合行 → metric_sample（origin='device' + 来源三键 + value_min/max/sample_count）。
public struct DeviceMetricRow: Sendable, Equatable {
    public var metricKey: String
    /// 窗口均值（睡眠=合并后总时长等汇总值）
    public var value: Double
    public var unit: String
    public var valueMin: Double?
    public var valueMax: Double?
    public var sampleCount: Int?
    public var sourceName: String?
    public var sourceVersion: String?
    public var sourceProduct: String?
    /// 窗口左边界（epoch；睡眠=夜锚日期）
    public var measuredAt: Date
    public var sourceRef: String?
    public var sourceIdentifier: String?
    public var aggregation: MetricAggregation?
    public var windowEnd: Date?
    public init(metricKey: String, value: Double, unit: String,
                valueMin: Double? = nil, valueMax: Double? = nil, sampleCount: Int? = nil,
                sourceName: String? = nil, sourceVersion: String? = nil,
                 sourceProduct: String? = nil, measuredAt: Date,
                 sourceRef: String? = nil, sourceIdentifier: String? = nil,
                 aggregation: MetricAggregation? = nil, windowEnd: Date? = nil) {
        self.metricKey = metricKey
        self.value = value
        self.unit = unit
        self.valueMin = valueMin
        self.valueMax = valueMax
        self.sampleCount = sampleCount
        self.sourceName = sourceName
        self.sourceVersion = sourceVersion
        self.sourceProduct = sourceProduct
        self.measuredAt = measuredAt
        self.sourceRef = sourceRef; self.sourceIdentifier = sourceIdentifier
        self.aggregation = aggregation; self.windowEnd = windowEnd
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
    public var guidelineID: UUID?
    public var guidelineVersion: String?
    public var citationURL: String?
    public var sourceIdentifier: String?
    public var sampleID: String?
    public var episodeStart: Date?
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

    private enum CodingKeys: String, CodingKey {
        case severity, levelTag, metricKey, value, unit, origin, measuredAt
        case sourceTitle, sourceOrg, sourceYear, sourceClause, path
        case guidelineID, guidelineVersion, citationURL, sourceIdentifier, sampleID, episodeStart
        case legacyFacts, legacySourceRef, legacyPath, legacyDisclaimer
        case facts, sourceRef, suggestedPath, disclaimer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(severity: try c.decode(AlertSeverity.self, forKey: .severity),
            levelTag: try c.decodeIfPresent(String.self, forKey: .levelTag),
            metricKey: try c.decodeIfPresent(String.self, forKey: .metricKey),
            value: try c.decodeIfPresent(Double.self, forKey: .value),
            unit: try c.decodeIfPresent(String.self, forKey: .unit),
            origin: try c.decodeIfPresent(String.self, forKey: .origin),
            measuredAt: try c.decodeIfPresent(Date.self, forKey: .measuredAt),
            sourceTitle: try c.decodeIfPresent(String.self, forKey: .sourceTitle),
            sourceOrg: try c.decodeIfPresent(String.self, forKey: .sourceOrg),
            sourceYear: try c.decodeIfPresent(Int.self, forKey: .sourceYear),
            sourceClause: try c.decodeIfPresent(String.self, forKey: .sourceClause),
            path: try c.decodeIfPresent(EvidencePath.self, forKey: .path),
            legacyFacts: try c.decodeIfPresent(String.self, forKey: .legacyFacts) ?? c.decodeIfPresent(String.self, forKey: .facts),
            legacySourceRef: try c.decodeIfPresent(String.self, forKey: .legacySourceRef) ?? c.decodeIfPresent(String.self, forKey: .sourceRef),
            legacyPath: try c.decodeIfPresent(String.self, forKey: .legacyPath) ?? c.decodeIfPresent(String.self, forKey: .suggestedPath),
            legacyDisclaimer: try c.decodeIfPresent(String.self, forKey: .legacyDisclaimer) ?? c.decodeIfPresent(String.self, forKey: .disclaimer))
        guidelineID = try c.decodeIfPresent(UUID.self, forKey: .guidelineID)
        guidelineVersion = try c.decodeIfPresent(String.self, forKey: .guidelineVersion)
        citationURL = try c.decodeIfPresent(String.self, forKey: .citationURL)
        sourceIdentifier = try c.decodeIfPresent(String.self, forKey: .sourceIdentifier)
        sampleID = try c.decodeIfPresent(String.self, forKey: .sampleID)
        episodeStart = try c.decodeIfPresent(Date.self, forKey: .episodeStart)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(severity, forKey: .severity)
        try c.encode(levelTag, forKey: .levelTag)
        try c.encodeIfPresent(metricKey, forKey: .metricKey)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(measuredAt, forKey: .measuredAt)
        try c.encodeIfPresent(sourceTitle, forKey: .sourceTitle)
        try c.encodeIfPresent(sourceOrg, forKey: .sourceOrg)
        try c.encodeIfPresent(sourceYear, forKey: .sourceYear)
        try c.encodeIfPresent(sourceClause, forKey: .sourceClause)
        try c.encodeIfPresent(path, forKey: .path)
        try c.encodeIfPresent(guidelineID, forKey: .guidelineID)
        try c.encodeIfPresent(guidelineVersion, forKey: .guidelineVersion)
        try c.encodeIfPresent(citationURL, forKey: .citationURL)
        try c.encodeIfPresent(sourceIdentifier, forKey: .sourceIdentifier)
        try c.encodeIfPresent(sampleID, forKey: .sampleID)
        try c.encodeIfPresent(episodeStart, forKey: .episodeStart)
        try c.encodeIfPresent(legacyFacts, forKey: .legacyFacts)
        try c.encodeIfPresent(legacySourceRef, forKey: .legacySourceRef)
        try c.encodeIfPresent(legacyPath, forKey: .legacyPath)
        try c.encodeIfPresent(legacyDisclaimer, forKey: .legacyDisclaimer)
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

    /// 单位同义标签归一（第七轮修复）：同一物理单位在信源库与录入路径的
    /// 标签不同（心率 bpm vs 次/分）——守卫判定前归一，非换算。
    /// 未识别标签原样返回（宁可少警的守卫语义不变）。
    /// 第八轮修复：补全角斜杠/带空格/「次/min」形态（OCR/IME 常见）——
    /// 「次／分」此前未归一而整条 L1 心率告警静默漏警。
    static func unitAlias(_ unit: String) -> String {
        switch unit {
        case "次/分", "次／分", "次 / 分", "次/min", "次／min",
             "次每分钟", "次/分钟", "次／分钟", "bpm", "beats/min", "beats/minute":
            return "bpm"
        default:
            return unit
        }
    }

    /// 单次读数定级：报告自带 A 级范围优先（FR16.4 铁律）；
    /// 无报告范围 → 信源库 B 级；无信源 → 不定级（范围不可用独立状态）
    public static func severity(for reading: MetricReading, guideline: GuidelineEntry?) -> AlertSeverity? {
        // 第六轮全仓审查修复：① NaN/∞（传感器失败读数）
        // 不得静默穿过全部比较落成 L0「健康」；② 双方单位均非空且不等时
        // 绝不跨单位比较数字——血糖信源为 mmol/L（3.9/7.0/13.9/16.7），
        // 110 mg/dL（≈6.1 mmol/L，正常）曾被 13.9 阈值定成 L2 并出证据卡。
        // 单位换算（mg/dL↔mmol/L 摩尔桥接）属 F25 接线批次，未接线前
        // 以「范围不可用」拒绝定级（宁可少警，不可错警）。
        guard reading.value.isFinite else { return nil }
        // A 级优先：报告自带参考范围
        if let report = reading.reportRange, report.grade == .A {
            if reading.value > report.upper || reading.value < report.lower {
                return .L1   // 报告范围越限 = 事实呈现，级别 L1（无 B 级阈值时不升级）
            }
            return .L0
        }
        guard let g = guideline else { return nil }   // 无信源 = 范围不可用
        let ru = reading.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let gu = g.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // 第七轮全仓审查修复：单位守卫只做 trim/lowercase，同一物理单位的
        // 两种标签被当成跨单位拒绝——心率信源 'bpm'（GuidelineSource）与
        // 语音/本地录入 '次/分'（VoiceGrammarDefaults）是同一单位，被拒后
        // 本地录入的心率 L1（AHA l1High=100）整体静默失效（宁可少警的红线
        // 被误伤）。守卫判定前先经同义归一（仅同义标签，非换算——
        // mg/dL↔mmol/L 摩尔桥接仍属 F25 接线批次，登记不在此实现）。
        let ruNorm = Self.unitAlias(ru)
        let guNorm = Self.unitAlias(gu)
        if !ru.isEmpty, !gu.isEmpty, gu != "1", ruNorm != guNorm { return nil }
        if let high = g.l3High, reading.value >= high { return .L3 }
        if let low = g.l3Low, reading.value <= low { return .L3 }
        if let high = g.l2High, reading.value >= high { return .L2 }
        if let low = g.l2Low, reading.value <= low { return .L2 }
        if let high = g.l1High, reading.value >= high { return .L1 }
        if let low = g.l1Low, reading.value <= low { return .L1 }
        return .L0
    }

    /// 评估序列中的定级读数（健康同步流用）。
    public struct GradedReading: Sendable, Equatable {
        public var reading: MetricReading
        /// nil = 范围不可用（拒绝定级）；.L0 = 未越限
        public var severity: AlertSeverity?
        public var episodeStart: Date?
        public init(reading: MetricReading, severity: AlertSeverity?) {
            self.reading = reading
            self.severity = severity
        }
    }

    /// FR16.2 持续性门槛（health-import V1.3 裁决：「同步流内分钟级内存态
    /// 评估，保连续 3 次读数/持续 10 分钟语义」）：定级序列（按时间升序）
    /// 中的连续越限 run——run 内读数 ≥3 次或 run 持续 ≥10 分钟——才升级为
    /// 提示。单次瞬时尖峰（运动心率抖动、传感器伪迹）不得触发 L1+ 通知；
    /// 无范围（nil）与 L0 均断开 run（宁可少警）。返回每个合格 run 的
    /// 锚定读数 = run 内定级最高者（同级取最晚）——证据卡呈现最差事实
    /// 读数，measuredAt 即 alert_event 幂等键（跨同步稳定）。
    public static func sustainedViolations(_ series: [GradedReading],
                                           sustainedWindow: TimeInterval = 10 * 60) -> [GradedReading] {
        let streams = Dictionary(grouping: series) { item in
            let r = item.reading
            return [r.metricKey, unitAlias(r.unit.lowercased()), r.origin.rawValue,
                    r.sourceIdentifier ?? r.sourceName ?? ""].joined(separator: "|")
        }
        var violations: [GradedReading] = []
        for stream in streams.values {
            let sorted = stream.sorted { $0.reading.measuredAt < $1.reading.measuredAt }
            var seen = Set<String>()
            var run: [GradedReading] = []
            for graded in sorted {
                let identity = graded.reading.sampleID
                    ?? "\(graded.reading.measuredAt.timeIntervalSince1970)|\(graded.reading.value)"
                guard seen.insert(identity).inserted else { continue }
                if let severity = graded.severity, severity != .L0 {
                    run.append(graded)
                } else {
                    violations.append(contentsOf: anchors(of: run, sustainedWindow: sustainedWindow))
                    run = []
                }
            }
            violations.append(contentsOf: anchors(of: run, sustainedWindow: sustainedWindow))
        }
        return violations.sorted { $0.reading.measuredAt < $1.reading.measuredAt }
    }

    /// 单个 run → 是否合格 → 锚定读数（run 内定级最高、同级取最晚）。
    private static func anchors(of run: [GradedReading],
                                sustainedWindow: TimeInterval) -> [GradedReading] {
        guard let first = run.first, let last = run.last else { return [] }
        let duration = last.reading.measuredAt.timeIntervalSince(first.reading.measuredAt)
        guard run.count >= consecutiveThreshold || duration >= sustainedWindow else { return [] }
        guard var anchor = run.max(by: { lhs, rhs in
            let li = AlertSeverity.allCases.firstIndex(of: lhs.severity ?? .L0) ?? 0
            let ri = AlertSeverity.allCases.firstIndex(of: rhs.severity ?? .L0) ?? 0
            if li != ri { return li < ri }
            return lhs.reading.measuredAt < rhs.reading.measuredAt
        }) else { return [] }
        anchor.episodeStart = first.reading.measuredAt
        return [anchor]
    }

    /// 连续 3 次越限 → 至少 L1（FR16.2 验收句）
    public static func escalate(recent: [MetricReading], guideline: GuidelineEntry?) -> AlertSeverity? {
        // 第六轮全仓审查修复：计数与判定必须同一窗口——原实现 levels.count
        // 对全数组计数、判定却只取 suffix(3)，两者错位；且空窗口
        // allSatisfy 恒真，窗口内仅 1 次越限即可升级（FR16.2「连续 3 次」
        // 口径被绕过）。修复：窗口内必须恰有 3 次全部定级且全部越限。
        guard recent.count >= consecutiveThreshold else { return nil }
        let last = recent.suffix(consecutiveThreshold)
        let lastLevels = last.compactMap { severity(for: $0, guideline: guideline) }
        guard lastLevels.count == consecutiveThreshold,
              lastLevels.allSatisfy({ $0 != .L0 }) else { return nil }
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
        var card = AlertEvidenceCard(
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
        card.guidelineID = guideline?.id
        card.guidelineVersion = guideline?.version
        card.citationURL = guideline?.citationUrl
        card.sourceIdentifier = reading.sourceIdentifier ?? reading.sourceName
        card.sampleID = reading.sampleID
        return card
    }
}
