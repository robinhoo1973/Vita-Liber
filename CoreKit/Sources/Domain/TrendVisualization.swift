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

    public func interval(endingAt now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        DateInterval(start: DayArithmetic.offset(days: -rawValue, from: now, calendar: calendar), end: now)
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
}
