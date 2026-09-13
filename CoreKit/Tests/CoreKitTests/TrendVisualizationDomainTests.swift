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
