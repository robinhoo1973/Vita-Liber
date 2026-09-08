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
    public init(totalAsleep: TimeInterval, perStage: [SleepStage: TimeInterval],
                inBedTotal: TimeInterval, sleepStart: Date? = nil, sleepEnd: Date? = nil,
                segmentCount: Int = 0, prioritySource: String? = nil) {
        self.totalAsleep = totalAsleep
        self.perStage = perStage
        self.inBedTotal = inBedTotal
        self.sleepStart = sleepStart
        self.sleepEnd = sleepEnd
        self.segmentCount = segmentCount
        self.prioritySource = prioritySource
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
        let dayStart = calendar.startOfDay(for: anchorDate)
        let windowStart = calendar.date(byAdding: .day, value: -1, to: dayStart)
            .flatMap { calendar.date(byAdding: .hour, value: 12, to: $0) } ?? anchorDate
        let windowEnd = calendar.date(byAdding: .hour, value: 24, to: windowStart) ?? anchorDate

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
        // ② 来源优先链（兜底手写链：product watch>phone>other → version 高者；
        //    HKStatisticsQuery 内置 sourceRevision 优先链为首选，成熟实现优先）
        let priorityName = clipped.max { lhs, rhs in
            sourceRank(lhs) < sourceRank(rhs)
        }?.sourceName
        // ③ 分期/未分期分流；分期并集
        let staged = clipped.filter { [.core, .deep, .rem].contains($0.stage) }
        let unspecified = clipped.filter { $0.stage == .unspecified }
        let stagedUnion = union(staged.map { ($0.start, $0.end) })
        // ④ 阶段优先：unspecified 逐段减去 staged 并集 → 浅睡未分期余段
        var unspecifiedRemainder: [(Date, Date)] = []
        for (s, e) in unspecified.map({ ($0.start, $0.end) }) {
            unspecifiedRemainder.append(contentsOf: subtract(s, e, stagedUnion))
        }
        // ⑤ 汇总
        var perStage: [SleepStage: TimeInterval] = [:]
        for (stage, spans) in [(SleepStage.deep, staged.filter { $0.stage == .deep }),
                               (SleepStage.rem, staged.filter { $0.stage == .rem }),
                               (SleepStage.core, staged.filter { $0.stage == .core })] {
            perStage[stage] = spans.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        }
        let unspecifiedTotal = unspecifiedRemainder.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
        perStage[.unspecified] = unspecifiedTotal
        let inBedUnion = union(clipped.filter { $0.stage == .inBed }.map { ($0.start, $0.end) })
        let asleepSpans = union((stagedUnion + unspecifiedRemainder).sorted { $0.0 < $1.0 })
        let totalAsleep = asleepSpans.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
        // ⑥ 分段计数：相邻入睡段 gap>30min 各成段
        var segmentCount = 0
        var lastEnd: Date?
        for (s, _) in asleepSpans.sorted(by: { $0.0 < $1.0 }) {
            if let lastEnd, s.timeIntervalSince(lastEnd) > segmentGap {
                segmentCount += 1
            } else if lastEnd == nil {
                segmentCount = 1
            }
            lastEnd = max(lastEnd ?? s, s)
        }
        return SleepNightSummary(
            totalAsleep: totalAsleep,
            perStage: perStage,
            inBedTotal: inBedUnion.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) },
            sleepStart: asleepSpans.map(\.0).min(),
            sleepEnd: asleepSpans.map(\.1).max(),
            segmentCount: segmentCount,
            prioritySource: priorityName)
    }

    /// 区间并集（gap≤mergeGap 相接即合并）
    static func union(_ intervals: [(Date, Date)]) -> [(Date, Date)] {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var out: [(Date, Date)] = []
        for interval in sorted {
            if let last = out.last, interval.0.timeIntervalSince(last.1) <= mergeGap {
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
        switch sample.sourceProduct?.lowercased() {
        case "watch": productRank = 3
        case "phone", "iphone": productRank = 2
        default: productRank = 1
        }
        return (productRank, sample.sourceVersion.flatMap(Int.init) ?? 0)
    }
}
