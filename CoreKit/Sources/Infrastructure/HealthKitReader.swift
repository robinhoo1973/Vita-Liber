#if os(iOS)
import Foundation
import HealthKit
import Domain
import Protocols

/// FR16.1 只读接入 Apple 健康：睡眠时长与分期、心率、静息心率、血氧、呼吸率、步数。
/// 只展示、不入诊断逻辑——读数经 AlertRuleEngine 与信源库比对后落 alert_event
/// （F16 四级提示的事实来源），任何「解释」都由证据卡引用式呈现。
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

    /// 近窗读数（默认 24 小时）：六指标 → [MetricReading]（引擎评估的事实源）。
    /// 第八轮全仓审查修复（3/6 覆盖缺口）：readTypes 授权了六类，但此处只
    /// 查静息心率/血氧/步数——即时心率、呼吸率、睡眠从未进 evaluateAndRecord，
    /// 心率（信源库已种 heart_rate l1High=100）的 L1 预警链整条空转，同步
    /// UI 仍报成功。补齐三类；呼吸率/睡眠信源库暂无种子 → 按 FR16.4 诚实
    /// 呈现「范围不可用」，绝不臆造阈值。
    public func recentReadings(within hours: Int = 24, now: Date = Date()) async throws -> [MetricReading] {
        guard HKHealthStore.isHealthDataAvailable() else { throw ReaderError.unavailable }
        let start = now.addingTimeInterval(TimeInterval(-hours * 3600))
        var readings: [MetricReading] = []
        // 静息心率（越限判断主指标之一）。
        // 审查修复：metricKey 必须与信源库种子键 snake_case 一致——
        // 驼峰 "heartRate" 查库恒空 → noApplicableRange → L1-L3 预警链整体失效。
        if let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) {
            let samples = try await querySamples(type: rhrType,
                                                 unit: HKUnit.count().unitDivided(by: .minute()),
                                                 from: start, to: now)
            for (value, at) in samples {
                readings.append(MetricReading(metricKey: "heart_rate",
                                              value: value, unit: "bpm",
                                              origin: .device, measuredAt: at))
            }
        }
        // 即时心率（键对齐信源库 "heart_rate"；取最新样本）
        if let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            let samples = try await querySamples(type: hrType,
                                                 unit: HKUnit.count().unitDivided(by: .minute()),
                                                 from: start, to: now)
            if let (lastValue, lastAt) = samples.last {
                readings.append(MetricReading(metricKey: "heart_rate",
                                              value: lastValue, unit: "bpm",
                                              origin: .device, measuredAt: lastAt))
            }
        }
        // 呼吸率（FR16.1 清单）
        if let rrType = HKQuantityType.quantityType(forIdentifier: .respiratoryRate) {
            let samples = try await querySamples(type: rrType,
                                                 unit: HKUnit.count().unitDivided(by: .minute()),
                                                 from: start, to: now)
            if let (lastValue, lastAt) = samples.last {
                readings.append(MetricReading(metricKey: "respiratory_rate",
                                              value: lastValue, unit: "br/min",
                                              origin: .device, measuredAt: lastAt))
            }
        }
        // 血氧（键对齐信源库 "blood_oxygen"；HK 值 0–1 分数 → %）
        if let spo2Type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) {
            let samples = try await querySamples(type: spo2Type,
                                                 unit: HKUnit.percent(),
                                                 from: start, to: now)
            for (value, at) in samples {
                readings.append(MetricReading(metricKey: "blood_oxygen",
                                              value: value * 100, unit: "%",
                                              origin: .device, measuredAt: at))
            }
        }
        // 步数（当日总量；单位=步数）
        if let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            let samples = try await querySamples(type: stepsType, unit: HKUnit.count(),
                                                 from: start, to: now)
            if let (lastValue, lastAt) = samples.last {
                readings.append(MetricReading(metricKey: "steps",
                                              value: lastValue, unit: "count",
                                              origin: .device, measuredAt: lastAt))
            }
        }
        // 睡眠（分类样本聚合：入睡/卧床时长与深睡占比；HKCategorySample
        // 不是数量样本，需独立查询助手）
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            readings.append(contentsOf: try await querySleepSamples(type: sleepType,
                                                                    from: start, to: now))
        }
        return readings
    }

    /// 睡眠分类样本聚合（FR16.1「睡眠时长与分期」）：asleep/inBed 总时长
    /// + 深睡（asleepDeep/REM/Core）时长，单位小时；无样本返回空数组。
    private func querySleepSamples(type: HKCategoryType, from: Date,
                                   to: Date) async throws -> [MetricReading] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: 500, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var asleep: TimeInterval = 0
                var inBed: TimeInterval = 0
                var deep: TimeInterval = 0
                var lastEnd: Date?
                for sample in (samples ?? []) {
                    guard let s = sample as? HKCategorySample else { continue }
                    let duration = s.endDate.timeIntervalSince(s.startDate)
                    switch s.value {
                    case HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                         HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                         HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                        deep += duration
                        asleep += duration
                    case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                        // .asleep 为 .asleepUnspecified 的旧名（iOS 16 弃用），rawValue 同值已覆盖
                        asleep += duration
                    case HKCategoryValueSleepAnalysis.inBed.rawValue:
                        inBed += duration
                    default:
                        break
                    }
                    lastEnd = s.endDate
                }
                var out: [MetricReading] = []
                guard let lastEnd else {
                    continuation.resume(returning: out)
                    return
                }
                if asleep > 0 {
                    out.append(MetricReading(metricKey: "sleep_duration",
                                             value: asleep / 3600, unit: "h",
                                             origin: .device, measuredAt: lastEnd))
                }
                if inBed > 0 {
                    out.append(MetricReading(metricKey: "sleep_in_bed",
                                             value: inBed / 3600, unit: "h",
                                             origin: .device, measuredAt: lastEnd))
                }
                if deep > 0 {
                    out.append(MetricReading(metricKey: "sleep_deep",
                                             value: deep / 3600, unit: "h",
                                             origin: .device, measuredAt: lastEnd))
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    /// 单类型样本查询（时间升序；单位由调用方按指标语义给定）
    private func querySamples(type: HKQuantityType, unit: HKUnit,
                              from: Date, to: Date) async throws -> [(Double, Date)] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: 100, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let out = (samples ?? []).compactMap { sample -> (Double, Date)? in
                    guard let q = sample as? HKQuantitySample else { return nil }
                    return (q.quantity.doubleValue(for: unit), q.endDate)
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }
}
#endif
