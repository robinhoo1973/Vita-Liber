import Foundation
import Testing
@testable import Domain

// binds: SU-M15-TREND
/// FR7.11 睡眠整合 Domain 纯函数金样（业主 2026-09-16 第 3 项）：
/// 一晚的六个时长投影键 → 按夜聚合的堆叠段（柱高 = 各段之和）+ 已排除集，
/// 以及宫格折叠（六个投影键只占一块瓦片）。只呈现事实，不含阈值判定（BR-003/004）。
@Suite("SU-M15-TREND · 睡眠整合（按夜堆叠 / 排除集 / 宫格折叠）")
struct SleepTrendDomainTests {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, _ hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func row(_ metric: MetricType, _ value: Double, at date: Date,
                     excluded: Bool = false, id: UUID = UUID()) -> SleepTrendRow {
        SleepTrendRow(metric: metric,
                      point: TrendPoint(id: id, measuredAt: date, value: value, unit: "h",
                                        origin: .device, excluded: excluded))
    }

    @Test("一晚六键聚合成一根堆叠柱：段按堆叠序、总量取 sleep_total、柱高 = 各段之和")
    func 按夜聚合() {
        let night = day(2026, 9, 14)
        let identity = TrendQueryIdentity(patientId: UUID(), metric: .sleepTotal,
                                          range: DateInterval(start: day(2026, 9, 13), end: day(2026, 9, 15)))
        let series = SleepTrendRules.series([
            row(.sleepTotal, 7.5, at: night),
            row(.sleepDeep, 1.2, at: night),
            row(.sleepCore, 4.0, at: night),
            row(.sleepREM, 1.8, at: night),
            row(.sleepAwake, 0.5, at: night),
        ], identity: identity, calendar: utc)

        #expect(series.nights.count == 1)
        #expect(series.identity == identity)
        let built = series.nights[0]
        #expect(built.day == utc.startOfDay(for: night))   // 日锚 = measured_at 所在日历日
        #expect(built.asleepHours == 7.5)                  // 总量 = sleep_total 投影（不臆造）
        #expect(built.slices.map(\.stage) == [.deep, .core, .rem, .awake])   // trendStack 序
        #expect(built.stackedHours == 7.5)                 // 1.2 + 4.0 + 1.8 + 0.5（柱高含清醒段）
        #expect(built.slices.allSatisfy { $0.hours > 0 })
        #expect(built.unit == "h")
        // 排除动作的作用集 = 各段原始行 **+ sleep_total 行**（总量行不进堆叠，
        // 但同属这一晚：漏掉它，宫格总时长瓦片会一直显示被排除的夜）
        #expect(built.pointIds.count == 5)
        #expect(built.totalPointIds.count == 1)
    }

    @Test("同一 (夜, 阶段) 多行取最大值且保留全部行 id：同夜多窗口物化不双计")
    func 同日去重不双计() {
        let night = day(2026, 9, 14)
        let first = UUID()
        let second = UUID()
        let series = SleepTrendRules.series([
            row(.sleepDeep, 0.8, at: night, id: first),    // 被 noon 锚窗裁剪的那份（更小）
            row(.sleepDeep, 1.4, at: night, id: second),   // 完整那份
        ], identity: nil, calendar: utc)
        #expect(series.nights.count == 1)
        #expect(series.nights[0].slices.count == 1)
        #expect(series.nights[0].slices[0].hours == 1.4)          // 取最大，不求和（8h+8h≈16h 同族）
        #expect(Set(series.nights[0].slices[0].pointIds) == Set([first, second]))
        #expect(series.nights[0].asleepHours == nil)              // 无 sleep_total 行 → 不臆造总量
        #expect(series.nights[0].stackedHours == 1.4)             // 柱高回落各段之和
    }

    @Test("排除行进 excludedNights（FR7.4 可恢复）：不混入可见夜，跨夜按日升序")
    func 排除集与跨夜排序() {
        let first = day(2026, 9, 13)
        let second = day(2026, 9, 14)
        let series = SleepTrendRules.series([
            row(.sleepTotal, 6.0, at: first),
            row(.sleepCore, 6.0, at: first),
            row(.sleepTotal, 0, at: second, excluded: true),      // 错值夜（已排除）
            row(.sleepDeep, 0, at: second, excluded: true),
        ], identity: nil, calendar: utc)
        #expect(series.nights.map(\.day) == [utc.startOfDay(for: first)])              // 可见夜只有前一夜
        #expect(series.excludedNights.map(\.day) == [utc.startOfDay(for: second)])     // 排除夜独立成集
        #expect(series.excludedNights[0].slices.map(\.stage) == [.deep])
    }

    @Test("宫格折叠：睡眠六键只出一块瓦片（sleep_total 恒胜），非睡眠行不动")
    func 宫格折叠() {
        // (key, value)：sleep_total 存在即代表该组
        let rows: [(String, Double)] = [
            ("glucose", 5.6), ("sleep_deep", 1.4), ("sleep_total", 7.5),
            ("sleep_rem", 1.5), ("heartRate", 72),
        ]
        let collapsed = SleepTrendRules.gridRows(rows,
                                                 metric: { MetricType(rawValue: $0.0) },
                                                 value: { $0.1 })
        #expect(collapsed.map(\.0) == ["glucose", "sleep_total", "heartRate"])
        // 无 total 行时取组内最大值的阶段行（瓦片名即该阶段名，不冒充总量）
        let onlyStage: [(String, Double)] = [("sleep_deep", 1.4), ("sleep_core", 4.0)]
        let fallback = SleepTrendRules.gridRows(onlyStage,
                                                metric: { MetricType(rawValue: $0.0) },
                                                value: { $0.1 })
        #expect(fallback.map(\.0) == ["sleep_core"])
    }

    @Test("睡眠族键集与阶段映射：单一事实源（含总量键无阶段）")
    func 族与阶段映射() {
        #expect(MetricType.sleepGroupKeys.count == 6)
        #expect(MetricType.sleepGroupKeys.filter { !$0.isSleep }.isEmpty)
        #expect(MetricType.sleepTotal.sleepStage == nil)
        #expect(MetricType.sleepDeep.sleepStage == .deep)
        #expect(MetricType.sleepCore.sleepStage == .core)
        #expect(MetricType.sleepREM.sleepStage == .rem)
        #expect(MetricType.sleepAwake.sleepStage == .awake)
        #expect(MetricType.sleepUnspecified.sleepStage == .unspecified)
        #expect(!MetricType.glucose.isSleep)
        // 堆叠自下而上：深睡在最下、清醒在最上（与 Apple Health 图例自上而下读同序）。
        // `inBed` 只在排序里兜底（存储不产该键——inBed 只进 inBedTotal），不参与比较。
        let storable = SleepStage.trendStack.filter { $0 != .inBed }
        #expect(storable == [.deep, .core, .unspecified, .rem, .awake])
    }
}
