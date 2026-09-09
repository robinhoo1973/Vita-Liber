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

    // MARK: - FR16.2 持续性门槛（sustainedViolations，health-import V1.3）

    private func graded(_ minutes: [Int], _ severities: [AlertSeverity?]) -> [AlertRuleEngine.GradedReading] {
        zip(minutes, severities).map { minute, severity in
            .init(reading: MetricReading(metricKey: "heart_rate", value: 105,
                                         unit: "bpm", origin: .device,
                                         measuredAt: date(9, 8, minute)),
                  severity: severity)
        }
    }

    @Test("连续 3 次越限 → 锚定末位读数（FR16.2 验收句）")
    func 连续三次越限() {
        let anchors = AlertRuleEngine.sustainedViolations(
            graded([0, 1, 2], [.L1, .L1, .L1]))
        #expect(anchors.count == 1)
        #expect(anchors[0].reading.measuredAt == date(9, 8, 2))
    }

    @Test("单次/两次越限不触发——瞬时尖峰不得提示")
    func 瞬时尖峰不触发() {
        #expect(AlertRuleEngine.sustainedViolations(graded([0], [.L1])).isEmpty)
        #expect(AlertRuleEngine.sustainedViolations(graded([0, 1], [.L1, .L1])).isEmpty)
    }

    @Test("持续 ≥10 分钟即触发（不足 3 次读数也成立）")
    func 持续时间门槛() {
        let anchors = AlertRuleEngine.sustainedViolations(
            graded([0, 11], [.L1, .L1]))
        #expect(anchors.count == 1, "2 次越限但持续 11 分钟必须触发")
        #expect(AlertRuleEngine.sustainedViolations(graded([0, 9], [.L1, .L1])).isEmpty,
                "9 分钟且 2 次读数为瞬态，不得触发")
    }

    @Test("L0 与范围不可用（nil）断开 run")
    func 低值断开() {
        // L1 L1 L0 L1 L1 —— run 被 L0 断开，两段各 2 次均不触发
        #expect(AlertRuleEngine.sustainedViolations(
            graded([0, 1, 2, 3, 4], [.L1, .L1, .L0, .L1, .L1])).isEmpty)
        // nil（无范围）同样断开
        #expect(AlertRuleEngine.sustainedViolations(
            graded([0, 1, 2, 3, 4], [.L1, .L1, nil, .L1, .L1])).isEmpty)
        // L1 L1 L1 L0 L2 L2 L2 —— 两段独立，第二段锚定其末位
        let anchors = AlertRuleEngine.sustainedViolations(
            graded([0, 1, 2, 3, 4, 5, 6], [.L1, .L1, .L1, .L0, .L2, .L2, .L2]))
        #expect(anchors.count == 2)
        #expect(anchors[1].reading.measuredAt == date(9, 8, 6))
    }

    @Test("run 内混合级别 → 锚定最高级读数（证据卡呈现最差事实）")
    func 锚定最高级() {
        let anchors = AlertRuleEngine.sustainedViolations(
            graded([0, 1, 2], [.L2, .L1, .L1]))
        #expect(anchors.count == 1)
        #expect(anchors[0].severity == .L2)
        #expect(anchors[0].reading.measuredAt == date(9, 8, 0))
    }

    @Test("空序列与乱序输入不崩溃")
    func 空序列() {
        #expect(AlertRuleEngine.sustainedViolations([]).isEmpty)
        // 乱序输入按时间排序后判定
        let anchors = AlertRuleEngine.sustainedViolations(
            graded([2, 0, 1], [.L1, .L1, .L1]))
        #expect(anchors.count == 1)
        #expect(anchors[0].reading.measuredAt == date(9, 8, 2))
    }

    // MARK: - 评估/入库双流值对象（FR7.9）

    @Test("Different metrics cannot jointly satisfy a sustained violation")
    func separateMetricStreams() {
        var samples = graded([0, 1, 2], [.L1, .L1, .L1])
        samples[1].reading.metricKey = "blood_oxygen"
        samples[1].reading.unit = "%"
        #expect(AlertRuleEngine.sustainedViolations(samples).isEmpty)
    }

    @Test("An unrelated normal reading does not break a heart-rate run")
    func unrelatedNormalReading() {
        var normal = graded([1], [.L0])[0]
        normal.reading.metricKey = "blood_oxygen"
        normal.reading.unit = "%"
        let result = AlertRuleEngine.sustainedViolations(
            graded([0, 2, 3], [.L1, .L1, .L1]) + [normal])
        #expect(result.count == 1)
        #expect(result.first?.reading.metricKey == "heart_rate")
    }

    @Test("Replayed samples do not manufacture three independent readings")
    func duplicateReadingDoesNotQualify() {
        let sample = graded([0], [.L1])[0]
        #expect(AlertRuleEngine.sustainedViolations([sample, sample, sample]).isEmpty)
    }

    @Test("A four-minute awake interval is not filled back into sleep")
    func shortAwakeningIsNotSleep() {
        let result = SleepMerge.merge([
            SleepSample(start: date(8, 23), end: date(9, 7), stage: .unspecified),
            SleepSample(start: date(9, 3), end: date(9, 3, 4), stage: .awake)
        ], anchorDate: date(9, 12), calendar: calendar)
        #expect(result.totalAsleep == 8 * 3600 - 240)
        #expect(result.perStage[.awake] == 240)
    }

    @Test("Conflicting sleep stages have exclusive duration")
    func conflictingStagesDoNotDoubleCount() {
        let result = SleepMerge.merge([
            SleepSample(start: date(8, 23), end: date(9, 0), stage: .deep,
                        sourceName: "Watch", sourceProduct: "Watch7,1"),
            SleepSample(start: date(8, 23), end: date(9, 0), stage: .rem,
                        sourceName: "Phone", sourceProduct: "iPhone16,1")
        ], anchorDate: date(9, 12), calendar: calendar)
        #expect(result.totalAsleep == 3600)
        #expect(result.perStage[.deep] == 3600)
        #expect((result.perStage[.rem] ?? 0) == 0)
    }

    @Test("Historical evidence retains its original facts and advice")
    func legacyEvidenceKeys() throws {
        let json = Data(#"{"severity":"L3","levelTag":"L3","facts":"original fact","sourceRef":"original source","suggestedPath":"original urgent path","disclaimer":"original disclaimer"}"#.utf8)
        let card = try JSONDecoder().decode(AlertEvidenceCard.self, from: json)
        #expect(card.legacyFacts == "original fact")
        #expect(card.legacySourceRef == "original source")
        #expect(card.legacyPath == "original urgent path")
        #expect(card.legacyDisclaimer == "original disclaimer")
    }

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

    // MARK: - 导入窗口与样本身份（二轮复审 P2：端点小时 / 时区无关身份）

    @Test("心率 series 恰在整点结束：覆盖窗口含端点小时（否则该小时聚合永不重算）")
    func 心率端点小时进覆盖窗口() {
        let series = HealthSampleReference(id: UUID(), kind: .heartRate, sourceID: "com.apple.health",
                                           start: date(9, 8, 55), end: date(9, 9))
        let windows = HealthImportWindow.covering(series, calendar: calendar)
        #expect(windows.map(\.start) == [date(9, 8), date(9, 9)])
    }

    @Test("步数/睡眠区间恰在边界结束不进下一窗口（累计与夜窗口语义不变）")
    func 区间样本边界不越窗() {
        let steps = HealthSampleReference(id: UUID(), kind: .steps, sourceID: "s",
                                          start: date(9, 23), end: date(10, 0))
        #expect(HealthImportWindow.covering(steps, calendar: calendar).map(\.start) == [date(9, 0)])
        let sleep = HealthSampleReference(id: UUID(), kind: .sleep, sourceID: "s",
                                          start: date(8, 23), end: date(9, 12))
        #expect(HealthImportWindow.covering(sleep, calendar: calendar).map(\.start) == [date(8, 12)])
    }

    @Test("离散样本身份不含日历日：时区/绑定变化后同一 UUID 仍命中同一行")
    func 离散样本身份时区无关() {
        let id = UUID()
        let identity = HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: id, ordinal: nil)
        #expect(identity == "hk:bloodOxygen:\(id.uuidString)")
        #expect(HealthImportWindow.sampleIdentity(kind: .respiratoryRate, sampleID: id, ordinal: 3)
                == "hk:respiratoryRate:\(id.uuidString):3")
        #expect(HealthImportWindow.sampleID(fromIdentity: identity, kind: .bloodOxygen) == id)
        #expect(HealthImportWindow.sampleID(fromIdentity: "hk:respiratoryRate:\(id.uuidString):3",
                                            kind: .respiratoryRate) == id)
        #expect(HealthImportWindow.sampleID(fromIdentity: "hk:heartRate:1700000000:com.apple", kind: .heartRate) == nil)
    }

    @Test("窗口归属：离散行按 measured_at 落窗，聚合行按窗口前缀落窗")
    func 窗口归属判定() {
        let day = HealthImportWindow(kind: .bloodOxygen, start: date(9, 0), end: date(10, 0))
        let inside = HealthImportWindow.sampleIdentity(kind: .bloodOxygen, sampleID: UUID(), ordinal: nil)
        #expect(day.contains(sourceRef: inside, measuredAt: date(9, 13)))
        #expect(!day.contains(sourceRef: inside, measuredAt: date(10, 0)))          // 半开区间
        #expect(!day.contains(sourceRef: "hk:heartRate:x", measuredAt: date(9, 13)))  // 类型不符
        let hour = HealthImportWindow(kind: .heartRate, start: date(9, 8), end: date(9, 9))
        #expect(hour.contains(sourceRef: hour.prefix + "com.apple.health", measuredAt: date(9, 8)))
        #expect(!hour.contains(sourceRef: "hk:heartRate:0:com.apple.health", measuredAt: date(9, 8)))
        #expect(hour.identityPrefix == hour.prefix)
        #expect(day.identityPrefix == "hk:bloodOxygen:")
    }

    @Test("Invalid health intervals never reach integer window identities")
    func invalidHealthIntervals() {
        for value in [Double.nan, .infinity, -.infinity, 1e30] {
            let ref = HealthSampleReference(id: UUID(), kind: .heartRate, sourceID: "watch",
                start: date(9, 8), end: Date(timeIntervalSince1970: value))
            #expect(!ref.isValid)
            #expect(HealthImportWindow.covering(ref, calendar: calendar).isEmpty)
        }
    }

    @Test("Discrete series ending at midnight includes the endpoint day")
    func discreteSeriesMidnightBoundary() {
        let ref = HealthSampleReference(id: UUID(), kind: .bloodOxygen, sourceID: "watch",
            start: date(9, 23, 59), end: date(10, 0))
        #expect(HealthImportWindow.covering(ref, calendar: calendar).map(\.start) == [date(9, 0), date(10, 0)])
    }

    @Test("Malformed series ordinals do not masquerade as a sample identity")
    func malformedSeriesIdentity() {
        let id = UUID()
        for suffix in [":-1", ":abc", ":1:2", ":"] {
            #expect(HealthImportWindow.sampleID(fromIdentity: "hk:bloodOxygen:\(id.uuidString)\(suffix)", kind: .bloodOxygen) == nil)
        }
    }

    @Test("Subsecond reversed intervals are invalid even if their persisted epoch values round together")
    func subsecondReversedInterval() {
        let end = Date(timeIntervalSinceReferenceDate: 721_699_200)
        let start = Date(timeIntervalSinceReferenceDate: 721_699_200 + 0.0000001)
        let ref = HealthSampleReference(id: UUID(), kind: .heartRate, sourceID: "watch", start: start, end: end)
        #expect(!ref.isValid)
        #expect(HealthImportWindow.covering(ref, calendar: calendar).isEmpty)
    }
}
