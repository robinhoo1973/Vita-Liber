import Foundation
import Testing
@testable import Domain

// binds: SU-M2-HEALTHSYNC
/// FR16.1/FR7.9 健康同步 Domain 纯函数金样（V3.86）：
/// 睡眠区间合并（双来源同夜双计修复 + deep 桶误计修复 + noon 锚归晚）与
/// 心率小时窗口聚合（min/max/avg + 最小样本数 + 非有限剔除）。
@Suite("SU-M2-HEALTHSYNC · 健康同步 Domain 纯函数")
struct HealthSyncDomainTests {

    /// 测试日历：固定 Asia/Shanghai（跨午夜样本的归晚语义与时区无关断言稳定）
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day,
                                           hour: hour, minute: minute))!
    }

    // MARK: - 睡眠合并（双来源同夜双计修复，health-import V1.3）

    @Test("双来源同夜不双计：staged 覆盖处忽略 unspecified（8h 而非 16h）")
    func 双来源同夜不双计() {
        // 真实场景：iPhone 自动判定整夜 asleepUnspecified 23:00-07:00（8h）
        // + Apple Watch 分期 core 00:30-03:30（3h）+ deep 03:30-04:30（1h）
        // + rem 04:30-05:30（1h）——合计入睡时长应为 8h，不得双计为 13h
        let samples = [
            SleepSample(start: date(8, 23), end: date(9, 7), stage: .unspecified,
                        sourceName: "iPhone", sourceProduct: "phone"),
            SleepSample(start: date(9, 0, 30), end: date(9, 3, 30), stage: .core,
                        sourceName: "Apple Watch", sourceProduct: "watch"),
            SleepSample(start: date(9, 3, 30), end: date(9, 4, 30), stage: .deep,
                        sourceName: "Apple Watch", sourceProduct: "watch"),
            SleepSample(start: date(9, 4, 30), end: date(9, 5, 30), stage: .rem,
                        sourceName: "Apple Watch", sourceProduct: "watch"),
        ]
        let summary = SleepMerge.merge(samples, anchorDate: date(9, 12), calendar: calendar)
        #expect(abs(summary.totalAsleep - 8 * 3600) < 1, "双计修复：total=\(summary.totalAsleep/3600)h")
        #expect(abs((summary.perStage[.deep] ?? 0) - 3600) < 1)
        #expect(abs((summary.perStage[.core] ?? 0) - 3 * 3600) < 1)
        #expect(abs((summary.perStage[.rem] ?? 0) - 3600) < 1)
        // unspecified 余段 = 23:00-00:30 + 05:30-07:00 = 3h
        #expect(abs((summary.perStage[.unspecified] ?? 0) - 3 * 3600) < 1)
        #expect(summary.prioritySource == "Apple Watch")   // watch > phone
        #expect(summary.segmentCount == 1)
    }

    @Test("双来源分期同夜按并集计（不按来源求和双计）")
    func 分期并集去重() {
        // Watch + 第三方睡眠 App 同夜各写重叠 core/deep——并集 1h deep 而非 2h
        let samples = [
            SleepSample(start: date(8, 23), end: date(9, 4), stage: .deep,
                        sourceName: "Apple Watch", sourceProduct: "watch"),
            SleepSample(start: date(8, 23, 30), end: date(9, 4, 30), stage: .deep,
                        sourceName: "Pillow", sourceProduct: "other"),
        ]
        let summary = SleepMerge.merge(samples, anchorDate: date(9, 12), calendar: calendar)
        // 并集 = [23:00, 04:30] = 5.5h；按来源求和 = 10h（双计）
        #expect(abs((summary.perStage[.deep] ?? 0) - 5.5 * 3600) < 60, "并集 5.5h，求和 10h 即双计")
    }

    @Test("awake 独立入桶并从未分期余段扣除（sleep_awake 行不再死分支）")
    func awake桶() {
        let samples = [
            SleepSample(start: date(8, 23), end: date(9, 7), stage: .unspecified),
            SleepSample(start: date(9, 3), end: date(9, 3, 30), stage: .awake),
        ]
        let summary = SleepMerge.merge(samples, anchorDate: date(9, 12), calendar: calendar)
        #expect(abs((summary.perStage[.awake] ?? 0) - 1800) < 1, "awake 30min 必须入桶")
        #expect(abs(summary.totalAsleep - 7.5 * 3600) < 1, "入睡时长不含醒着的时间")
    }

    @Test("分段 gap 按前段结束计（长段后短间隔不分段）")
    func 段间距按段末() {
        let samples = [
            SleepSample(start: date(8, 23), end: date(9, 1), stage: .unspecified),
            SleepSample(start: date(9, 1, 40), end: date(9, 3), stage: .unspecified),
            SleepSample(start: date(9, 3, 20), end: date(9, 7), stage: .unspecified),
        ]
        let summary = SleepMerge.merge(samples, anchorDate: date(9, 12), calendar: calendar)
        // gap：01:00→01:40 = 40min（>30 分段）；03:00→03:20 = 20min（同段）
        #expect(summary.segmentCount == 2, "起点计 gap 会误判为 3 段")
    }

    @Test("deep 桶只计 deep（REM/Core 不再误计入 deep，V1.3 修正）")
    func deep桶修正() {
        let samples = [
            SleepSample(start: date(8, 23), end: date(9, 2), stage: .core),
            SleepSample(start: date(9, 2), end: date(9, 5), stage: .deep),
            SleepSample(start: date(9, 5), end: date(9, 7), stage: .rem),
        ]
        let summary = SleepMerge.merge(samples, anchorDate: date(9, 12), calendar: calendar)
        #expect(abs((summary.perStage[.deep] ?? 0) - 3 * 3600) < 1, "deep=3h（旧实现 core+deep+rem=8h 全入 deep）")
        #expect(abs((summary.perStage[.core] ?? 0) - 3 * 3600) < 1)
        #expect(abs(summary.totalAsleep - 8 * 3600) < 1)
    }

    @Test("noon 锚归晚：跨午夜归入睡前日，跨界样本裁剪")
    func noon锚归晚() {
        // 睡眠 9/8 22:30 → 9/9 06:30；以 9/9 为锚日（窗口=9/8 12:00 → 9/9 12:00）
        let samples = [SleepSample(start: date(8, 22, 30), end: date(9, 6, 30), stage: .unspecified)]
        let summary = SleepMerge.merge(samples, anchorDate: date(9, 12), calendar: calendar)
        #expect(abs(summary.totalAsleep - 8 * 3600) < 1)
        #expect(summary.sleepStart == date(8, 22, 30))
        // 窗口外样本不落本晚：9/7 22:00-23:00（9/8 锚日窗口之外）不计入
        let outside = SleepSample(start: date(7, 22), end: date(7, 23), stage: .unspecified)
        let summary2 = SleepMerge.merge([samples[0], outside], anchorDate: date(9, 12), calendar: calendar)
        #expect(abs(summary2.totalAsleep - 8 * 3600) < 1)
    }

    @Test("同日多段小睡：gap>30min 各成段")
    func 多段小睡分段() {
        // 锚日 9/9（窗口=9/8 12:00 → 9/9 12:00）：9/8 午睡 1h + 夜睡 8h
        let samples = [
            SleepSample(start: date(8, 13), end: date(8, 14), stage: .unspecified),   // 午睡 1h
            SleepSample(start: date(8, 22), end: date(9, 6), stage: .unspecified),    // 夜睡 8h
        ]
        let summary = SleepMerge.merge(samples, anchorDate: date(9, 12), calendar: calendar)
        #expect(summary.segmentCount == 2)
        #expect(abs(summary.totalAsleep - 9 * 3600) < 1)
    }

    @Test("空样本返回零值摘要不崩溃")
    func 空样本() {
        let summary = SleepMerge.merge([], anchorDate: date(9, 12), calendar: calendar)
        #expect(summary.totalAsleep == 0)
        #expect(summary.segmentCount == 0)
    }

    // MARK: - 小时窗口聚合（FR16.1 min/max/avg）

    @Test("整点窗口聚合 min/max/avg 与左边界")
    func 小时窗口聚合() {
        let samples = [
            HourWindowSample(value: 80, at: date(9, 8, 5)),
            HourWindowSample(value: 100, at: date(9, 8, 20)),
            HourWindowSample(value: 90, at: date(9, 8, 50)),
            HourWindowSample(value: 70, at: date(9, 9, 10)),   // 次窗口
        ]
        let (windows, rejected) = HourWindowAggregator.aggregate(samples, calendar: calendar)
        #expect(rejected == 0)
        #expect(windows.count == 1)   // 09:00 窗口仅 1 个有效样本（<3 不落行）
        let w = windows[0]
        #expect(w.windowStart == date(9, 8))
        #expect(abs(w.avg - 90) < 0.001)
        #expect(w.min == 80)
        #expect(w.max == 100)
        #expect(w.sampleCount == 3)
    }

    @Test("最小样本数门槛：<3 不落行")
    func 最小样本门槛() {
        let samples = [HourWindowSample(value: 80, at: date(9, 8, 5)),
                       HourWindowSample(value: 90, at: date(9, 8, 20))]
        let (windows, _) = HourWindowAggregator.aggregate(samples, calendar: calendar)
        #expect(windows.isEmpty)
    }

    @Test("非有限值剔除计数（不静默；0/负值保留交评估）")
    func 非有限剔除() {
        let samples = [HourWindowSample(value: .infinity, at: date(9, 8, 5)),
                       HourWindowSample(value: .nan, at: date(9, 8, 10)),
                       HourWindowSample(value: 80, at: date(9, 8, 20)),
                       HourWindowSample(value: 0, at: date(9, 8, 30)),   // 保留（可能是真读数）
                       HourWindowSample(value: 90, at: date(9, 8, 40))]
        let (windows, rejected) = HourWindowAggregator.aggregate(samples, calendar: calendar)
        #expect(rejected == 2)
        #expect(windows.count == 1)
        #expect(windows[0].sampleCount == 3)   // 80 + 0 + 90
    }

    // MARK: - 评估/入库双流值对象（FR7.9）

    @Test("DeviceMetricRow 幂等键含来源形态")
    func deviceMetricRow形态() {
        let row = DeviceMetricRow(metricKey: "heart_rate", value: 80, unit: "bpm",
                                  valueMin: 70, valueMax: 100, sampleCount: 60,
                                  sourceName: "Apple Watch", sourceVersion: "9.0",
                                  sourceProduct: "watch",
                                  measuredAt: date(9, 8))
        #expect(row.sourceName == "Apple Watch")
        #expect(row.sampleCount == 60)
    }

    @Test("MetricReading 来源元数据向后兼容（扩展字段默认 nil）")
    func metricReading向后兼容() {
        let legacy = MetricReading(metricKey: "heart_rate", value: 80, unit: "bpm",
                                   origin: .device, measuredAt: date(9, 8))
        #expect(legacy.sourceName == nil)
        #expect(legacy.sourceProduct == nil)
    }
}
