#if os(iOS)
import Foundation
import HealthKit
import Domain
import Protocols

/// FR16.1 只读接入 Apple 健康：睡眠时长与分期、心率、静息心率、血氧、呼吸率、步数。
/// 只展示、不入诊断逻辑——读数经 AlertRuleEngine 与信源库比对后落 alert_event
/// （F16 四级提示的事实来源），任何「解释」都由证据卡引用式呈现。
///
/// V3.86 评估与入库双流（FR7.9）：`recentReadings` 供分钟级内存态评估
/// （心率返回窗口内全部原始样本，保 FR16.2「连续3次/持续10分钟」语义）；
/// `deviceRows` 供小时窗口聚合落库（心率 min/max/avg、睡眠区间合并——
/// 杜绝双来源同夜双计，health-import V1.3）。
///
/// 授权被拒 → 整体降级为手动自测模式（FR7.5），不反复弹索权（FR16.1 边界）。
public actor HealthKitReader {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) { self.store = store }

    public enum ReaderError: Error, LocalizedError {
        case unavailable
        case denied
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "HealthKit 在此设备不可用"
            case .denied: return "健康数据读取未获授权"
            }
        }
    }

    /// 六指标读取类型（FR16.1 清单）
    public static let readTypes: Set<HKObjectType> = {
        var types: Set<HKObjectType> = []
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        if let hr = HKQuantityType.quantityType(forIdentifier: .heartRate) { types.insert(hr) }
        if let rhr = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) { types.insert(rhr) }
        if let spo2 = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) { types.insert(spo2) }
        if let rr = HKQuantityType.quantityType(forIdentifier: .respiratoryRate) { types.insert(rr) }
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) { types.insert(steps) }
        return types
    }()

    /// 请求只读授权（一次性；拒绝后降级手测模式，不反复弹）
    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw ReaderError.unavailable }
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    /// 授权状态查询（FR16.1 审查修复：requestAuthorization 对用户拒绝
    /// **不抛错**、completion 也是 success——必须显式查 authorizationStatus，
    /// 否则拒绝被误报为「已授权」、同步按钮空转、降级手测路径永不呈现）
    public func authorizationStatus() -> HKAuthorizationStatus? {
        guard HKHealthStore.isHealthDataAvailable(),
              let hr = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return nil }
        return store.authorizationStatus(for: hr)
    }

    // MARK: - 评估流（分钟级内存态，FR16.2 语义）

    /// 近窗读数（默认 24 小时）：六指标 → [MetricReading]（引擎评估的事实源）。
    /// V3.86：即时心率返回窗口内**全部**原始样本（保「连续3次/持续10分钟」
    /// 评估语义）；睡眠改为合并摘要（sleep_total 族键，杜绝双来源双计）。
    public func recentReadings(within hours: Int = 24, now: Date = Date(),
                               calendar: Calendar = .current) async throws -> [MetricReading] {
        guard HKHealthStore.isHealthDataAvailable() else { throw ReaderError.unavailable }
        let start = now.addingTimeInterval(TimeInterval(-hours * 3600))
        var readings: [MetricReading] = []
        if let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) {
            let samples = try await querySamples(type: rhrType,
                                                 unit: HKUnit.count().unitDivided(by: .minute()),
                                                 from: start, to: now)
            for (value, at, source) in samples {
                readings.append(MetricReading(metricKey: "heart_rate",
                                              value: value, unit: "bpm",
                                              origin: .device, measuredAt: at,
                                              sourceName: source?.source.name,
                                              sourceVersion: source?.version,
                                              sourceProduct: source?.productType))
            }
        }
        if let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            let samples = try await querySamples(type: hrType,
                                                 unit: HKUnit.count().unitDivided(by: .minute()),
                                                 from: start, to: now, limit: 1500)
            for (value, at, source) in samples {
                readings.append(MetricReading(metricKey: "heart_rate",
                                              value: value, unit: "bpm",
                                              origin: .device, measuredAt: at,
                                              sourceName: source?.source.name,
                                              sourceVersion: source?.version,
                                              sourceProduct: source?.productType))
            }
        }
        if let rrType = HKQuantityType.quantityType(forIdentifier: .respiratoryRate) {
            let samples = try await querySamples(type: rrType,
                                                 unit: HKUnit.count().unitDivided(by: .minute()),
                                                 from: start, to: now)
            if let (lastValue, lastAt, source) = samples.last {
                readings.append(MetricReading(metricKey: "respiratory_rate",
                                              value: lastValue, unit: "br/min",
                                              origin: .device, measuredAt: lastAt,
                                              sourceName: source?.source.name,
                                              sourceVersion: source?.version,
                                              sourceProduct: source?.productType))
            }
        }
        if let spo2Type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) {
            let samples = try await querySamples(type: spo2Type,
                                                 unit: HKUnit.percent(),
                                                 from: start, to: now)
            for (value, at, source) in samples {
                readings.append(MetricReading(metricKey: "blood_oxygen",
                                              value: value * 100, unit: "%",
                                              origin: .device, measuredAt: at,
                                              sourceName: source?.source.name,
                                              sourceVersion: source?.version,
                                              sourceProduct: source?.productType))
            }
        }
        if let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            let samples = try await querySamples(type: stepsType, unit: HKUnit.count(),
                                                 from: start, to: now)
            if let (lastValue, lastAt, source) = samples.last {
                readings.append(MetricReading(metricKey: "steps",
                                              value: lastValue, unit: "count",
                                              origin: .device, measuredAt: lastAt,
                                              sourceName: source?.source.name,
                                              sourceVersion: source?.version,
                                              sourceProduct: source?.productType))
            }
        }
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            let rows = try await sleepRows(type: sleepType, from: start, to: now, calendar: calendar)
            for row in rows {
                readings.append(MetricReading(metricKey: row.metricKey,
                                              value: row.value, unit: row.unit,
                                              origin: .device, measuredAt: row.measuredAt,
                                              sourceName: row.sourceName))
            }
        }
        return readings
    }

    // MARK: - 入库流（小时窗口聚合，FR7.9）

    /// 设备读数落库行：心率小时窗口聚合（min/max/avg + 来源主键）+
    /// 睡眠区间合并（sleep_total/deep/rem/awake）+ 血氧/呼吸率/步数单值行。
    public func deviceRows(within hours: Int = 24, now: Date = Date(),
                           calendar: Calendar = .current) async throws -> [DeviceMetricRow] {
        guard HKHealthStore.isHealthDataAvailable() else { throw ReaderError.unavailable }
        let start = now.addingTimeInterval(TimeInterval(-hours * 3600))
        var rows: [DeviceMetricRow] = []
        // 心率：原始分钟级样本 → Domain 小时窗口聚合（value=avg + min/max + count）
        if let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            let samples = try await querySamples(type: hrType,
                                                 unit: HKUnit.count().unitDivided(by: .minute()),
                                                 from: start, to: now, limit: 1500)
            // 按小时+来源分组：同窗口多来源取样本数最多的来源为主键（幂等键含来源）
            var bucketSources: [Date: [String: Int]] = [:]
            var windowSamples: [Date: [HourWindowSample]] = [:]
            for (value, at, source) in samples {
                let bucket = calendar.dateInterval(of: .hour, for: at)?.start
                    ?? calendar.startOfDay(for: at)
                windowSamples[bucket, default: []].append(HourWindowSample(value: value, at: at))
                bucketSources[bucket, default: [:]][source?.source.name ?? "", default: 0] += 1
            }
            let (windows, _) = HourWindowAggregator.aggregate(
                windowSamples.values.flatMap { $0 }, calendar: calendar)
            for window in windows {
                let sourceName = bucketSources[window.windowStart]?.max(by: { $0.value < $1.value })?.key
                rows.append(DeviceMetricRow(
                    metricKey: "heart_rate", value: window.avg, unit: "bpm",
                    valueMin: window.min, valueMax: window.max,
                    sampleCount: window.sampleCount, sourceName: sourceName,
                    measuredAt: window.windowStart))
            }
        }
        // 睡眠：分类样本 → 区间合并（Domain SleepMerge，阶段优先+noon 锚归晚）
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            rows.append(contentsOf: try await sleepRows(type: sleepType, from: start, to: now,
                                                        calendar: calendar))
        }
        // 血氧/呼吸率：窗口内最新单值（来源元数据随行）
        if let spo2Type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) {
            let samples = try await querySamples(type: spo2Type, unit: HKUnit.percent(),
                                                 from: start, to: now)
            if let (lastValue, lastAt, source) = samples.last {
                rows.append(DeviceMetricRow(metricKey: "blood_oxygen",
                                            value: lastValue * 100, unit: "%",
                                            sourceName: source?.source.name,
                                            sourceVersion: source?.version,
                                            sourceProduct: source?.productType,
                                            measuredAt: lastAt))
            }
        }
        if let rrType = HKQuantityType.quantityType(forIdentifier: .respiratoryRate) {
            let samples = try await querySamples(type: rrType,
                                                 unit: HKUnit.count().unitDivided(by: .minute()),
                                                 from: start, to: now)
            if let (lastValue, lastAt, source) = samples.last {
                rows.append(DeviceMetricRow(metricKey: "respiratory_rate",
                                            value: lastValue, unit: "br/min",
                                            sourceName: source?.source.name,
                                            sourceVersion: source?.version,
                                            sourceProduct: source?.productType,
                                            measuredAt: lastAt))
            }
        }
        if let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            let samples = try await querySamples(type: stepsType, unit: HKUnit.count(),
                                                 from: start, to: now)
            if let (lastValue, lastAt, source) = samples.last {
                rows.append(DeviceMetricRow(metricKey: "steps",
                                            value: lastValue, unit: "count",
                                            sourceName: source?.source.name,
                                            sourceVersion: source?.version,
                                            sourceProduct: source?.productType,
                                            measuredAt: lastAt))
            }
        }
        return rows
    }

    /// 睡眠合并行（V3.86）：HKCategorySample → Domain SleepSample →
    /// SleepMerge.merge（区间并集/阶段优先/noon 锚归晚）→ sleep_total 族键。
    /// deep 桶只计 deep（V1.3 修正：REM/Core 不再误计入 deep）。
    private func sleepRows(type: HKCategoryType, from: Date, to: Date,
                           calendar: Calendar) async throws -> [DeviceMetricRow] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
        let samples: [SleepSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: 500, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var out: [SleepSample] = []
                for case let s as HKCategorySample in (samples ?? []) {
                    let stage: SleepStage
                    switch s.value {
                    case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: stage = .deep
                    case HKCategoryValueSleepAnalysis.asleepREM.rawValue: stage = .rem
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue: stage = .core
                    // .asleep 为 .asleepUnspecified 的旧名（iOS 16 弃用），rawValue 同值
                    case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: stage = .unspecified
                    case HKCategoryValueSleepAnalysis.awake.rawValue: stage = .awake
                    case HKCategoryValueSleepAnalysis.inBed.rawValue: stage = .inBed
                    default: continue
                    }
                    out.append(SleepSample(
                        start: s.startDate, end: s.endDate, stage: stage,
                        sourceName: s.sourceRevision.source.name,
                        sourceVersion: s.sourceRevision.version,
                        sourceProduct: s.sourceRevision.productType))
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
        // noon 锚归晚：按样本结束日的自然日分组（merge 内部取前一日 12:00 窗）
        var rows: [DeviceMetricRow] = []
        for day in Set(samples.map { calendar.startOfDay(for: $0.end) }) {
            let summary = SleepMerge.merge(samples, anchorDate: day, calendar: calendar)
            guard summary.totalAsleep > 0 || summary.inBedTotal > 0 else { continue }
            let anchor = summary.sleepStart ?? day
            if summary.totalAsleep > 0 {
                rows.append(DeviceMetricRow(metricKey: "sleep_total",
                                            value: summary.totalAsleep / 3600, unit: "h",
                                            sourceName: summary.prioritySource,
                                            measuredAt: anchor))
            }
            if let deep = summary.perStage[.deep], deep > 0 {
                rows.append(DeviceMetricRow(metricKey: "sleep_deep",
                                            value: deep / 3600, unit: "h",
                                            sourceName: summary.prioritySource,
                                            measuredAt: anchor))
            }
            if let rem = summary.perStage[.rem], rem > 0 {
                rows.append(DeviceMetricRow(metricKey: "sleep_rem",
                                            value: rem / 3600, unit: "h",
                                            sourceName: summary.prioritySource,
                                            measuredAt: anchor))
            }
            if let awake = summary.perStage[.awake], awake > 0 {
                rows.append(DeviceMetricRow(metricKey: "sleep_awake",
                                            value: awake / 3600, unit: "h",
                                            sourceName: summary.prioritySource,
                                            measuredAt: anchor))
            }
        }
        return rows
    }

    // MARK: - 前台锚点增量（FR16.1 V3.46：HKAnchoredObjectQuery 兜底）

    /// 锚点增量查询（单类型）：返回自 anchor 以来的样本事件与删除事件。
    /// 无锚首跑传 nil（全量）。
    public func anchoredChanges(type: HKObjectType, anchor: HKQueryAnchor?,
                                limit: Int = 500) async throws -> (anchor: HKQueryAnchor?,
                                                                   added: [HKObject],
                                                                   deletedCount: Int) {
        try await withCheckedThrowingContinuation { continuation in
            // 单次 resume 纪律：resultsHandler 可在后续更新时再次回调——
            // settled 守卫（与 SFSpeechTranscriber isFinal 守卫同款），
            // 双 resume 是 continuation 陷阱
            var settled = false
            let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor,
                                              limit: limit) { _, samples, deleted, newAnchor, error in
                guard !settled else { return }
                settled = true
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (newAnchor, samples ?? [], deleted))
                }
            }
            store.execute(query)
        }
    }

    /// 单类型样本查询（时间升序；单位由调用方按指标语义给定）。
    /// 返回 (值, 时刻, 来源修订)——来源三键供幂等键与展示徽章。
    private func querySamples(type: HKQuantityType, unit: HKUnit,
                              from: Date, to: Date,
                              limit: Int = 100) async throws -> [(Double, Date, HKSourceRevision?)] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: limit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let out = (samples ?? []).compactMap { sample -> (Double, Date, HKSourceRevision?)? in
                    guard let q = sample as? HKQuantitySample else { return nil }
                    return (q.quantity.doubleValue(for: unit), q.endDate, q.sourceRevision)
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }
}
#endif
