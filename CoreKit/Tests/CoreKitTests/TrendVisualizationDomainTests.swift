import Foundation
import Testing
@testable import Domain

// binds: SU-M15-TREND
/// FR7.11 趋势可视化 Domain 纯函数金样（round2 H2/H4，trend-visualization-module-spec）：
/// 查询身份四元、日历日时间窗、按指标图型族、保极值降采样——只呈现统计事实，不含阈值判定（BR-003/004）。
@Suite("SU-M15-TREND · 趋势查询身份 / 时间窗 / 图型族 / 降采样")
struct TrendVisualizationDomainTests {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    @Test("时间窗为日历日区间：DST 切换日时长 ≠ rawValue×86400（可见域与查询范围同源）")
    /// 原名：时间窗DST
    func timeWindowDST() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08 美东进入夏令时：窗口 03-05→03-12 跨春令时切换，时长 = 7×86400 − 3600
        let end = ny.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 12))!
        let interval = TrendTimeWindow.week.interval(endingAt: end, calendar: ny)
        #expect(interval.duration == TimeInterval(7) * 86400 - 3600)
        #expect(interval.end == end)
    }

    @Test("H4 降采样保极值：每桶保留 min/max，点数 ≤ 2×buckets+2，极值不丢，输出按时间有序")
    /// 原名：降采样
    func downsampling() {
        let start = Date(timeIntervalSince1970: 0)
        let range = DateInterval(start: start, duration: 3600 * 1000)
        func value(_ i: Int) -> Double {
            if i == 500 { return 999 }
            if i == 700 { return -5 }
            return Double(i % 50)
        }
        let points: [TrendPoint] = (0..<1000).map { i in
            TrendPoint(id: UUID(), measuredAt: start.addingTimeInterval(Double(i) * 3600),
                       value: value(i), origin: .device)
        }
        let thinned = TrendDownsampler.thin(points, in: range, maxBuckets: 100)
        #expect(thinned.count <= 202)
        #expect(thinned.count >= 100)                       // 每桶至少一点，稀疏化不是清空
        #expect(thinned.contains { $0.value == 999 })       // 全局最大值保留
        #expect(thinned.contains { $0.value == -5 })        // 全局最小值保留
        #expect(thinned.map(\.measuredAt) == thinned.map(\.measuredAt).sorted())
        #expect(thinned.first?.id == points.first?.id)      // 首尾点补齐
        #expect(thinned.last?.id == points.last?.id)
        #expect(Set(thinned.map(\.id)).count == thinned.count)   // 不重复输出同一点
    }

    @Test("H4 降采样：点数不超上限原样返回；无效参数原样返回")
    /// 原名：降采样不越界
    func downsamplingWithinBounds() {
        let start = Date(timeIntervalSince1970: 0)
        let range = DateInterval(start: start, duration: 3600 * 1000)
        let points = (0..<50).map { i in
            TrendPoint(id: UUID(), measuredAt: start.addingTimeInterval(Double(i) * 3600), value: Double(i), origin: .manual)
        }
        #expect(TrendDownsampler.thin(points, in: range, maxBuckets: 100) == points)
        #expect(TrendDownsampler.thin(points, in: range, maxBuckets: 0) == points)
        #expect(TrendDownsampler.thin(points, in: DateInterval(start: start, duration: 0), maxBuckets: 10) == points)
        #expect(TrendDownsampler.thin([], in: range, maxBuckets: 10).isEmpty)
        // 范围外的点落入首/末桶而非崩溃
        let outside = points + [TrendPoint(id: UUID(), measuredAt: start.addingTimeInterval(-1), value: 1, origin: .manual)]
        #expect(TrendDownsampler.thin(outside, in: range, maxBuckets: 10).count <= 22)
    }

    @Test("H4 图型族按指标：步数日柱 / 心率小时区间 / 睡眠时长柱 / 血压成对 / 其余点")
    /// 原名：图型族
    func chartKindFamilies() {
        #expect(TrendMarkFamily.family(for: .steps) == .dailyBars)
        #expect(TrendMarkFamily.family(for: .heartRate) == .hourlyRange)
        for sleep in [MetricType.sleepTotal, .sleepDeep, .sleepREM, .sleepAwake, .sleepCore, .sleepUnspecified] {
            #expect(TrendMarkFamily.family(for: sleep) == .durationBars)
        }
        #expect(TrendMarkFamily.family(for: .bloodPressureSys) == .pairedPoints)
        #expect(TrendMarkFamily.family(for: .bloodPressureDia) == .pairedPoints)
        for discrete in [MetricType.glucose, .weight, .temperature, .bloodOxygen, .restingHeartRate, .respiratoryRate] {
            #expect(TrendMarkFamily.family(for: discrete) == .points)
        }
    }

    @Test("时间窗为日历日窗；四档 rawValue 即天数")
    /// 原名：时间窗
    func timeWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(TrendTimeWindow.allCases.map(\.rawValue) == [7, 30, 90, 365])
        for window in TrendTimeWindow.allCases {
            let interval = window.interval(endingAt: now, calendar: utc)
            #expect(interval.end == now)
            #expect(utc.dateComponents([.day], from: interval.start, to: interval.end).day == window.rawValue)
            #expect(window.id == window.rawValue)
        }
    }

    @Test("周期翻页：长度不变、相邻不重叠、锚点日可回溯（业主第 4 项）")
    /// 原名：周期翻页
    func periodPaging() {
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        for window in TrendTimeWindow.allCases {
            // offset 0 = 锚点所在周期（不含未来）：0 档与历史 interval 逐字同构
            let current = window.period(endingAt: anchor, calendar: utc)
            #expect(current == window.interval(endingAt: anchor, calendar: utc))
            #expect(current.end == anchor)
            #expect(current.start <= anchor && anchor <= current.end)     // 锚点读数落在 0 档周期内
            // 显式步进（paged）：一档 = rawValue 个日历日
            let stepBack = window.paged(by: 1, from: anchor, calendar: utc)
            #expect(utc.dateComponents([.day], from: stepBack, to: anchor).day == window.rawValue)
            // 相邻周期：上一周期的末 = 本周期的始（不重叠、不留缝），长度不变
            let oneBack = window.period(endingAt: anchor, offset: 1, calendar: utc)
            #expect(oneBack.end == stepBack)
            #expect(oneBack.end == current.start)
            #expect(oneBack.duration == current.duration)
            // 单调向更早
            let twoBack = window.period(endingAt: anchor, offset: 2, calendar: utc)
            #expect(twoBack.end == oneBack.start)
            #expect(twoBack.end < oneBack.end && oneBack.end < current.end)
            // 负偏移按 0 档处理（不构造未来周期）
            #expect(window.period(endingAt: anchor, offset: -3, calendar: utc) == current)
        }
    }

    @Test("折线断段阈值：降采样后才随桶宽放大，未降采样恒按采样步长（缺测不插值）")
    /// 原名：断段阈值
    func segmentGapThreshold() {
        let start = Date(timeIntervalSince1970: 0)
        let week = TrendTimeWindow.week.interval(endingAt: start.addingTimeInterval(7 * 86400), calendar: utc)
        let year = TrendTimeWindow.year.interval(endingAt: start.addingTimeInterval(365 * 86400), calendar: utc)
        // 未降采样（点数 ≤ 2×桶数）：无论窗口多长都按采样步长判缺测——
        // 90 天窗内只有 200 条小时读数时，桶宽（13.5h）与数据实际间距无关，
        // 用它当阈值会把相隔 12h 的两次读数插值连起来（缺测不插值一票否决）
        #expect(TrendDownsampler.gapThreshold(range: week, pointCount: 100) == 5400)
        #expect(TrendDownsampler.gapThreshold(range: year, pointCount: 200) == 5400)
        #expect(TrendDownsampler.gapThreshold(range: year, pointCount: TrendDownsampler.maxBuckets * 2) == 5400)
        // 降采样发生：阈值 ≥ 桶宽（相邻保留点跨度天然 ≈ 桶宽，仍按小时判缺测会让
        // 每个保留点都成新段，1 年心率的折线与 min/max 带整条消失）
        let dense = TrendDownsampler.maxBuckets * 2 + 1
        let yearGap = TrendDownsampler.gapThreshold(range: year, pointCount: dense)
        let bucketWidth = year.duration / Double(TrendDownsampler.maxBuckets)
        #expect(yearGap > 3600)
        // 相邻桶的保留点最大可相距 ≈ 2×桶宽（桶内留的是极值两点，落在桶内任意时刻），
        // 故阈值须 ≥ 2×桶宽才真正保证「抽稀不会制造断段」
        #expect(yearGap >= bucketWidth * 2)
        // 退化区间（零长）不产生 0 阈值（否则任何两点都断段）
        #expect(TrendDownsampler.gapThreshold(range: DateInterval(start: start, duration: 0), pointCount: dense) == 5400)
    }

    @Test("身份四元任一不同即不等；TrendSeries 携身份默认 nil")
    /// 原名：查询身份
    func queryIdentity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let w = TrendTimeWindow.month.interval(endingAt: now, calendar: utc)
        let a = TrendQueryIdentity(patientId: UUID(), metric: .heartRate, origin: .device, range: w)
        #expect(a == TrendQueryIdentity(patientId: a.patientId, metric: .heartRate, origin: .device, range: w))
        #expect(a != TrendQueryIdentity(patientId: UUID(), metric: .heartRate, origin: .device, range: w))
        #expect(a != TrendQueryIdentity(patientId: a.patientId, metric: .glucose, origin: .device, range: w))
        #expect(a != TrendQueryIdentity(patientId: a.patientId, metric: .heartRate, origin: nil, range: w))
        #expect(a != TrendQueryIdentity(patientId: a.patientId, metric: .heartRate, origin: .device,
                                        range: TrendTimeWindow.week.interval(endingAt: now, calendar: utc)))
        #expect(TrendQueryIdentity(patientId: a.patientId, metric: .heartRate, range: w).origin == nil)   // 默认全部来源
        #expect(TrendSeries(metricType: .heartRate, points: [], identity: a).identity == a)
        #expect(TrendSeries(metricType: .heartRate, points: []).identity == nil)
        #expect(Set([a, a]).count == 1)   // Hashable：可作 task id / 缓存键
    }
}
