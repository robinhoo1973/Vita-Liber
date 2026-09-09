import Foundation

/// FR16.1 睡眠区间合并（health-import-spec V1.3 / tech §5.29 V3.86）：
/// 双来源同夜样本（iPhone 自动判定整夜 asleepUnspecified 与 Apple Watch
/// 分期 core/deep/rem 并存）按区间并集合并——**杜绝同夜时长双计**
/// （此前按来源直接求和：8h unspecified + 8h 分期 ≈ 16h，真实 8h）。
/// 阶段优先：staged（core/deep/rem）覆盖处忽略 unspecified，余段=浅睡未分期。
/// noon 锚夜归属：入睡前一日 12:00 起 24h=一晚，跨界样本按交集裁剪、
/// 跨午夜归入睡前日；同日多段小睡 gap>30min 各成段。Domain 纯函数，金样单测。

public enum SleepStage: String, Sendable, Equatable, CaseIterable, Codable {
    case inBed
    case awake
    case core
    case deep
    case rem
    case unspecified   // 旧版/自动判定整夜样本（.asleep 旧名同值）
}

public struct SleepSample: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var stage: SleepStage
    /// HKSource 三键（幂等/来源优先链用）
    public var sourceName: String?
    public var sourceVersion: String?
    public var sourceProduct: String?
    public init(start: Date, end: Date, stage: SleepStage,
                sourceName: String? = nil, sourceVersion: String? = nil,
                sourceProduct: String? = nil) {
        self.start = start
        self.end = end
        self.stage = stage
        self.sourceName = sourceName
        self.sourceVersion = sourceVersion
        self.sourceProduct = sourceProduct
    }
}

public struct SleepNightSummary: Sendable, Equatable {
    /// 入睡类并集总时长（staged 并集 + 未分期余段）
    public var totalAsleep: TimeInterval
    /// 各阶段时长（deep/rem/core 为分期并集；unspecified 为余段）
    public var perStage: [SleepStage: TimeInterval]
    public var inBedTotal: TimeInterval
    public var sleepStart: Date?
    public var sleepEnd: Date?
    /// 入睡段数（gap>30min 各成段——同日多段小睡可辨）
    public var segmentCount: Int
    /// 命中的最高优先来源名（诊断呈现；无来源信息为 nil）
    public var prioritySource: String?
    /// 归窗左边界（noon 锚窗口 [前日12:00, 当日12:00) 的左端；技术 §5.29
    /// 睡眠聚合键 measured_at=窗口左边界语义——跨同步稳定，供幂等键锚定）
    public var windowStart: Date?
    public init(totalAsleep: TimeInterval, perStage: [SleepStage: TimeInterval],
                inBedTotal: TimeInterval, sleepStart: Date? = nil, sleepEnd: Date? = nil,
                segmentCount: Int = 0, prioritySource: String? = nil,
                windowStart: Date? = nil) {
        self.totalAsleep = totalAsleep
        self.perStage = perStage
        self.inBedTotal = inBedTotal
        self.sleepStart = sleepStart
        self.sleepEnd = sleepEnd
        self.segmentCount = segmentCount
        self.prioritySource = prioritySource
        self.windowStart = windowStart
    }
}

public enum SleepMerge {
    /// 相接合并阈值：gap ≤5min 视为同一段（区间并集）
    public static let mergeGap: TimeInterval = 5 * 60
    /// 分段阈值：gap >30min 视为新入睡段
    public static let segmentGap: TimeInterval = 30 * 60

    /// 合并入口：anchorDate = 要归属的「入睡日」任一日历日（按 noon 锚归窗）。
    /// 返回窗内合并摘要；样本全空返回零值摘要。
    public static func merge(_ samples: [SleepSample], anchorDate: Date,
                             calendar: Calendar = .current) -> SleepNightSummary {
        // noon 锚：入睡前一日 12:00 起 24h 为「一晚」（睡眠日记惯例）
        let windowEnd = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: anchorDate) ?? anchorDate
        let windowStart = calendar.date(byAdding: .day, value: -1, to: windowEnd) ?? anchorDate

        // ① 窗口裁剪（跨午夜样本按交集裁剪；跨窗样本只计窗内部分）
        var clipped: [SleepSample] = []
        for sample in samples {
            let start = max(sample.start, windowStart)
            let end = min(sample.end, windowEnd)
            guard end > start else { continue }
            var s = sample
            s.start = start
            s.end = end
            clipped.append(s)
        }
        // Each interval is assigned once; episode grouping must never fill unobserved time.
        let priorityName = clipped.max { lhs, rhs in
            if sourceRank(lhs) != sourceRank(rhs) { return sourceRank(lhs) < sourceRank(rhs) }
            return (lhs.sourceName ?? "") > (rhs.sourceName ?? "")
        }?.sourceName
        var perStage: [SleepStage: TimeInterval] = [:]
        var asleepIntervals: [(Date, Date)] = []
        let boundaries = Set(clipped.flatMap { [$0.start, $0.end] }).sorted()
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            let active = clipped.filter { $0.start < end && $0.end > start && $0.stage != .inBed }
            let stage: SleepStage
            if active.contains(where: { $0.stage == .awake }) {
                stage = .awake
            } else {
                let staged = active.filter { $0.stage != .unspecified }
                let candidates = (staged.isEmpty ? active : staged).sorted {
                    if sourceRank($0) != sourceRank($1) { return sourceRank($0) > sourceRank($1) }
                    return ($0.sourceName ?? "") < ($1.sourceName ?? "")
                }
                guard let preferred = candidates.first else { continue }
                let sameSource = candidates.filter {
                    $0.sourceName == preferred.sourceName && sourceRank($0) == sourceRank(preferred)
                }
                stage = Set(sameSource.map(\.stage)).count > 1 ? .unspecified : preferred.stage
            }
            perStage[stage, default: 0] += end.timeIntervalSince(start)
            if stage != .awake { asleepIntervals.append((start, end)) }
        }
        let inBedUnion = union(clipped.filter { $0.stage == .inBed }.map { ($0.start, $0.end) })
        let asleepSpans = union(asleepIntervals)
        let totalAsleep = asleepSpans.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
        // ⑥ 分段计数：相邻入睡段 gap>30min 各成段——gap 按「前段结束→后段
        //    开始」计（此前 lastEnd 记录的是前段**起点**，段长 >30min 时
        //    下一段恒被判为新段：23:00-03:00 + 03:10-07:00 的 10min 醒来
        //    被误计为 2 段）
        var segmentCount = 0
        var lastEnd: Date?
        for (s, e) in asleepSpans.sorted(by: { $0.0 < $1.0 }) {
            if let lastEnd, s.timeIntervalSince(lastEnd) > segmentGap {
                segmentCount += 1
            } else if lastEnd == nil {
                segmentCount = 1
            }
            lastEnd = e
        }
        return SleepNightSummary(
            totalAsleep: totalAsleep,
            perStage: perStage,
            inBedTotal: inBedUnion.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) },
            sleepStart: asleepSpans.map(\.0).min(),
            sleepEnd: asleepSpans.map(\.1).max(),
            segmentCount: segmentCount,
            prioritySource: priorityName,
            windowStart: windowStart)
    }

    /// Actual coverage union: gaps never contribute measured duration.
    static func union(_ intervals: [(Date, Date)]) -> [(Date, Date)] {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var out: [(Date, Date)] = []
        for interval in sorted {
            if let last = out.last, interval.0 <= last.1 {
                out[out.count - 1] = (last.0, max(last.1, interval.1))
            } else {
                out.append(interval)
            }
        }
        return out
    }

    /// 区间减法：interval − others → 余段（不产生负区间）
    static func subtract(_ start: Date, _ end: Date,
                         _ others: [(Date, Date)]) -> [(Date, Date)] {
        var fragments: [(Date, Date)] = [(start, end)]
        for other in others {
            var next: [(Date, Date)] = []
            for (s, e) in fragments {
                if other.1 <= s || other.0 >= e {
                    next.append((s, e))
                    continue
                }
                if other.0 > s { next.append((s, other.0)) }
                if other.1 < e { next.append((other.1, e)) }
            }
            fragments = next
        }
        return fragments
    }

    /// 来源优先：product（watch>phone>other）→ version（高者优先）
    static func sourceRank(_ sample: SleepSample) -> (Int, Int) {
        let productRank: Int
        let product = sample.sourceProduct?.lowercased() ?? ""
        if product.hasPrefix("watch") { productRank = 3 }
        else if product.hasPrefix("iphone") || product == "phone" { productRank = 2 }
        else { productRank = 1 }
        return (productRank, sample.sourceVersion.flatMap(Int.init) ?? 0)
    }
}
