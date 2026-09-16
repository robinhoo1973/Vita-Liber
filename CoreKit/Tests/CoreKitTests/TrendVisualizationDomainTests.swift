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
    func 时间窗DST() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08 美东进入夏令时：窗口 03-05→03-12 跨春令时切换，时长 = 7×86400 − 3600
        let end = ny.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 12))!
        let interval = TrendTimeWindow.week.interval(endingAt: end, calendar: ny)
        #expect(interval.duration == TimeInterval(7) * 86400 - 3600)
        #expect(interval.end == end)
    }

    @Test("H4 降采样保极值：每桶保留 min/max，点数 ≤ 2×buckets+2，极值不丢，输出按时间有序")
    func 降采样() {
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
    func 降采样不越界() {
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
    func 图型族() {
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
    func 时间窗() {
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
    func 周期翻页() {
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

    @Test("折线断段阈值 ≥ 桶宽：降采样后不得把每个保留点判成缺测")
    func 断段阈值() {
        let start = Date(timeIntervalSince1970: 0)
        // 短窗：7 天 240 桶 → 桶宽 2520s < 小时步长 → 阈值保持 5400s（既有行为不变）
        let week = DateInterval(start: start, duration: 7 * 86400)
        #expect(TrendDownsampler.gapThreshold(range: week) == 5400)
        // 长窗：365 天 240 桶 → 桶宽 ≈ 1.52 天 → 阈值必须随桶宽放大，否则
        // 每个保留点都被判成新段（1 年心率的折线与 min/max 带整条消失）
        let year = DateInterval(start: start, duration: 365 * 86400)
        let yearGap = TrendDownsampler.gapThreshold(range: year)
        #expect(yearGap > 3600)
        #expect(yearGap >= year.duration / Double(TrendDownsampler.maxBuckets))
        // 退化区间（零长）不产生 0 阈值（否则任何两点都断段）
        #expect(TrendDownsampler.gapThreshold(range: DateInterval(start: start, duration: 0)) == 5400)
    }

    @Test("身份四元任一不同即不等；TrendSeries 携身份默认 nil")
    func 查询身份() {
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
