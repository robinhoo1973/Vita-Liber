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

    /// 近窗读数（默认 24 小时）：六指标 → [MetricReading]（引擎评估的事实源）
    public func recentReadings(within hours: Int = 24, now: Date = Date()) async throws -> [MetricReading] {
        guard HKHealthStore.isHealthDataAvailable() else { throw ReaderError.unavailable }
        let start = now.addingTimeInterval(TimeInterval(-hours * 3600))
        var readings: [MetricReading] = []
        // 静息心率（越限判断主指标之一）
        if let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) {
            let samples = try await querySamples(type: rhrType,
                                                 unit: HKUnit.count().unitDivided(by: .minute()),
                                                 from: start, to: now)
            for (value, at) in samples {
                readings.append(MetricReading(metricKey: "heartRate",
                                              value: value, unit: "count/min",
                                              origin: .device, measuredAt: at))
            }
        }
        // 血氧
        if let spo2Type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) {
            let samples = try await querySamples(type: spo2Type,
                                                 unit: HKUnit.percent(),
                                                 from: start, to: now)
            for (value, at) in samples {
                readings.append(MetricReading(metricKey: "bloodOxygen",
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
        return readings
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
