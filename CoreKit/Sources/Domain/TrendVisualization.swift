import Foundation

/// FR7.11 趋势可视化组件层 Domain 基础能力（trend-visualization-module-spec；round2 H2/H4）。
/// 纯统计呈现：查询身份、时间窗、图型族、降采样——不含任何阈值/正常异常判定（BR-003/004）。

/// 趋势查询身份四元（round2 H2）：查询携带并回传，渲染层按身份丢弃过期/错位结果——
/// 旧实现用「请求代次」单校验，晚到的旧身份结果仍可能落槽（切成员/切指标时短暂串图）。
public struct TrendQueryIdentity: Sendable, Hashable {
    public let patientId: UUID
    public let metric: MetricType
    /// nil = 全部来源；`.device` 只可能归属本人绑定（BR-001，Infrastructure 强制）
    public let origin: MetricOrigin?
    public let range: DateInterval

    public init(patientId: UUID, metric: MetricType, origin: MetricOrigin? = nil, range: DateInterval) {
        self.patientId = patientId
        self.metric = metric
        self.origin = origin
        self.range = range
    }
}

/// 时间窗四档（rawValue = 日历日天数；DayArithmetic 出口，DST 纪律）
public enum TrendTimeWindow: Int, CaseIterable, Sendable, Identifiable {
    case week = 7, month = 30, quarter = 90, year = 365

    public var id: Int { rawValue }

    /// 距今 N 个日历日的窗口（历史签名；逐字等于 `period(endingAt: now, offset: 0)`）
    public func interval(endingAt now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        period(endingAt: now, calendar: calendar)
    }

    /// 周期（翻页单位，业主 2026-09-16 第 4 项）：长度恒为 rawValue 日历日，
    /// `endingAt` = 周期末（锚点），`offset` = **向更早**平移的周期数（0 = 锚点所在周期）。
    ///
    /// 为什么锚点可参数化（而不是恒为「现在」）：指标读数天然稀疏——最近 7/30/90 天
    /// 常常一条读数都没有，而半年前有（设备投影按窗口由旧到新物化，近期窗口最后到达）。
    /// 窗口钉死在「现在」时短窗只能渲染空态，1 年窗却能渲染（业主 2026-09-16 实测：
    /// 「点击 7 天/30 天/90 天与 1 年显示大不相同，明显是数据没有渲染」）。把周期末
    /// 提为状态，既让首屏锚定到「有数据的周期」，也让 ‹ › 在同一长度下前后翻阅。
    public func period(endingAt anchor: Date, offset: Int = 0, calendar: Calendar = .current) -> DateInterval {
        // offset ≤ 0 直接取锚点本身（不绕 Calendar 加法）：`end` 与传入锚点逐位相等，
        // 渲染层的「周期是否就是本页请求的那一段」判定才可用于相等比较。
        let end = offset <= 0 ? anchor : paged(by: offset, from: anchor, calendar: calendar)
        return DateInterval(start: DayArithmetic.offset(days: -rawValue, from: end, calendar: calendar), end: end)
    }

    /// 翻页步进（ui-ux §4.17 PagingStepper 语义）：整体平移一个周期，长度不变——
    /// steps > 0 = 更早，steps < 0 = 更近。日历日一律经 DayArithmetic（DST 不漂移）。
    /// 锚点取「最新读数所在日」（无读数回落今天），故 offset ≥ 0 构造出的周期恒不含未来。
    public func paged(by steps: Int, from anchor: Date, calendar: Calendar = .current) -> Date {
        DayArithmetic.offset(days: -steps * rawValue, from: anchor, calendar: calendar)
    }
}

/// 按指标选图型（round2 H4）：步数日总量 / 睡眠时长 = 柱；心率小时窗 = 均值折线 + min/max 区间；
/// 血压 sys/dia = 成对点（双序列由路由按 metric 成对加载）；其余离散读数 = 点。
public enum TrendMarkFamily: Sendable, Equatable {
    case points, dailyBars, hourlyRange, durationBars, pairedPoints

    public static func family(for metric: MetricType) -> TrendMarkFamily {
        switch metric {
        case .steps: return .dailyBars
        case .heartRate: return .hourlyRange
        case .sleepTotal, .sleepDeep, .sleepREM, .sleepAwake, .sleepCore, .sleepUnspecified: return .durationBars
        case .bloodPressureSys, .bloodPressureDia: return .pairedPoints
        case .glucose, .weight, .temperature, .bloodOxygen, .restingHeartRate, .respiratoryRate: return .points
        }
    }
}

/// 保极值降采样（round2 H4）：心率一年小时窗 8760 点直接入 Swift Charts 掉帧；
/// 可见范围内等宽分桶，每桶保留 min/max 两点（同点则一），补首尾点——极值永不因抽稀消失。
public enum TrendDownsampler {
    /// 图形降采样桶数（单一事实源）：视图的 gap 阈值与降采样共用同一常量——
    /// 两处各写字面量时，调桶数就会让断段阈值与桶宽脱钩（见 `gapThreshold`）。
    public static let maxBuckets = 240

    /// - Returns: 点数 ≤ 2×maxBuckets + 2，按时间升序；点数 ≤ 2×maxBuckets 或参数无效时原样返回。
    public static func thin(_ points: [TrendPoint], in range: DateInterval, maxBuckets: Int) -> [TrendPoint] {
        guard maxBuckets > 0, points.count > maxBuckets * 2, range.duration > 0 else { return points }
        let width = range.duration / Double(maxBuckets)
        var kept: [Int: (lo: TrendPoint, hi: TrendPoint)] = [:]
        for point in points {
            let offset = point.measuredAt.timeIntervalSince(range.start) / width
            // 范围外的点夹到首/末桶（非有限偏移按首桶处理，不崩溃）
            let raw = offset.isFinite ? Int(Swift.max(0, Swift.min(Double(maxBuckets - 1), offset.rounded(.down)))) : 0
            let index = Swift.min(maxBuckets - 1, Swift.max(0, raw))
            guard var slot = kept[index] else {
                kept[index] = (point, point)
                continue
            }
            if point.value < slot.lo.value { slot.lo = point }
            if point.value > slot.hi.value { slot.hi = point }
            kept[index] = slot
        }
        var out: [TrendPoint] = []
        var seen = Set<UUID>()
        func append(_ point: TrendPoint) {
            guard seen.insert(point.id).inserted else { return }
            out.append(point)
        }
        for index in kept.keys.sorted() {
            guard let slot = kept[index] else { continue }
            append(slot.lo)
            append(slot.hi)
        }
        if let first = points.first { append(first) }
        if let last = points.last { append(last) }
        return out.sorted { $0.measuredAt < $1.measuredAt }
    }

    /// 折线断段阈值（数据诚实 gap 断线，FR7.11③）：`contiguousSegments` 用它判断
    /// 「相邻点之间算缺测还是算连续」。阈值必须**不小于桶宽**——降采样后相邻保留点的
    /// 时间跨度天然 ≈ 桶宽，仍按采样步长（小时）判缺测会把每个保留点都判成新段：
    /// 1 年心率（8760 点 → 240 桶 → 桶宽 ≈ 1.5 天）的均值折线与 min/max 区间带
    /// 随之整条消失，只剩孤立点（业主实测「短窗与 1 年显示大不相同」的同族）。
    /// 短窗（桶宽 ≤ 采样步长）结果不变：7 天窗 → max(5400s, 3780s) = 5400s。
    public static func gapThreshold(range: DateInterval, samplingInterval: TimeInterval = 3600,
                                    maxBuckets: Int = TrendDownsampler.maxBuckets) -> TimeInterval {
        let bucketWidth = range.duration / Double(Swift.max(1, maxBuckets))
        return Swift.max(samplingInterval * 1.5, bucketWidth * 1.5)
    }
}
