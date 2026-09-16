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
    /// 为什么锚点可参数化（而不是恒为「现在」）：趋势页进页锚定**今天**
    /// （业主 2026-09-16 第 1 项：「数据显示的起点应该是当前日期，而不是最近的那条记录」），
    /// ‹ › 则在同一长度下把锚点整体前移/后移——「上一个周期比这个周期怎么样」
    /// 必须能问，不能只有最初那一屏。
    /// 读数天然稀疏（设备投影按窗口由旧到新物化，近期窗口最后到达）时空周期是
    /// 合法状态：页面给事实（「最近读数：X」）与出口（跳到该读数所在周期），
    /// 但不把锚点搬走——锚点搬走后「7 天」显示的不是最近 7 天，页面失去「今天」这个参照点。
    public func period(endingAt anchor: Date, offset: Int = 0, calendar: Calendar = .current) -> DateInterval {
        // offset ≤ 0 直接取锚点本身（不绕 Calendar 加法）：`end` 与传入锚点逐位相等，
        // 渲染层的「周期是否就是本页请求的那一段」判定才可用于相等比较。
        let end = offset <= 0 ? anchor : paged(by: offset, from: anchor, calendar: calendar)
        return DateInterval(start: DayArithmetic.offset(days: -rawValue, from: end, calendar: calendar), end: end)
    }

    /// 翻页步进（ui-ux §4.17 PagingStepper 语义）：整体平移一个周期，长度不变——
    /// steps > 0 = 更早，steps < 0 = 更近。日历日一律经 DayArithmetic（DST 不漂移）。
    /// 锚点取「今天」（业主 2026-09-16 第 1 项），故 offset ≥ 0 构造出的周期恒不含未来。
    public func paged(by steps: Int, from anchor: Date, calendar: Calendar = .current) -> Date {
        DayArithmetic.offset(days: -steps * rawValue, from: anchor, calendar: calendar)
    }

    /// 翻页落点（FR7.11；2026-09-16 第 1 项批）：**边界判定属业务规则，落在 Domain**
    /// ——返回 nil = 落点已达/越过 `limit`（今天），即「已在当前周期」，
    /// 视图据此回落自动锚定（periodEnd = nil）并置灰更近方向。
    ///
    /// 为什么边界要有正反两处都调用的同一函数：视图此前把同一条边界写成两处
    /// 不同严格度的比较（`periodEnd < newestEnd` 判可用、`next >= newestEnd` 判落点），
    /// 两处任一处改动就会让「按钮可点但点了没反应」或「有更近周期却点不动」。
    /// 更近方向的界是**今天**（而不是最新读数所在日）：读数之间的空周期是
    /// 合法可翻阅的区间，最新读数所在日不再是页面的锚点。
    public func paged(by steps: Int, from anchor: Date, cappedAt limit: Date,
                      calendar: Calendar = .current) -> Date? {
        let next = paged(by: steps, from: anchor, calendar: calendar)
        return next >= limit ? nil : next
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
    /// 「相邻点之间算缺测还是算连续」。**阈值与「本序列是否真的被降采样过」同源**：
    ///
    /// - 降采样发生（`pointCount > maxBuckets × 2`，与 `thin` 同一判据）时，相邻保留点的
    ///   时间跨度天然 ≈ 桶宽，阈值必须不小于**两倍**桶宽——桶内保留的是极值两点，
    ///   它们落在桶内的任意时刻，故相邻桶的保留点最大可相距 ≈ 2×桶宽；只取 1×（或
    ///   1.5×）时，抽稀本身仍会制造断段，1 年心率（8760 点 → 240 桶 ≈ 1.5 天/桶）的
    ///   均值折线与 min/max 区间带仍会零散断开（业主实测「短窗与 1 年显示大不相同」的同族）。
    ///   → max(采样步长×1.5, 桶宽×2)
    /// - 未降采样时**不得**用桶宽：桶宽只是「如果抽稀会用的粒度」，与数据实际间距无关。
    ///   90 天窗里只有 200 条小时读数（200 ≤ 480，`thin` 原样返回）时，桶宽（13.5 h）
    ///   与实况无关，于是相隔 12 h 的两条读数被判成连续，被 `.monotone` 折线**插值连起来**
    ///   ——这是「缺测不插值」一票否决的反面（阈值只有下界就会桥接真实缺测）。
    ///   → 采样步长×1.5 = 5400s（7 天窗历史行为不变）
    public static func gapThreshold(range: DateInterval, pointCount: Int,
                                    samplingInterval: TimeInterval = 3600,
                                    maxBuckets: Int = TrendDownsampler.maxBuckets) -> TimeInterval {
        guard pointCount > maxBuckets * 2 else { return samplingInterval * 1.5 }
        let bucketWidth = range.duration / Double(Swift.max(1, maxBuckets))
        return Swift.max(samplingInterval * 1.5, bucketWidth * 2)
    }
}
