#if os(iOS)
import Foundation
import HealthKit
import Domain
import Protocols

/// Read-only HealthKit adapter. Read authorization is deliberately not observable by apps.
public actor HealthKitReader: HealthReadingProvider {
    private let store: HKHealthStore
    private var observers: [HKObserverQuery] = []
    public init(store: HKHealthStore = HKHealthStore()) { self.store = store }

    public enum ReaderError: Error { case unavailable, invalidAnchor, incompleteSnapshot }

    public static var readTypes: Set<HKObjectType> {
        Set(HealthDataKind.allCases.map { sampleType($0) as HKObjectType })
    }

    private static func sampleType(_ kind: HealthDataKind) -> HKSampleType {
        switch kind {
        case .heartRate: return HKQuantityType(.heartRate)
        case .restingHeartRate: return HKQuantityType(.restingHeartRate)
        case .bloodOxygen: return HKQuantityType(.oxygenSaturation)
        case .respiratoryRate: return HKQuantityType(.respiratoryRate)
        case .steps: return HKQuantityType(.stepCount)
        case .sleep: return HKCategoryType(.sleepAnalysis)
        }
    }

    public func isAvailable() -> Bool { HKHealthStore.isHealthDataAvailable() }

    public func requestAuthorization() async throws {
        guard isAvailable() else { throw ReaderError.unavailable }
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    public func observeChanges(handler: @escaping @Sendable () async -> Bool,
                               enableDelivery: Bool) async -> Bool {
        if observers.isEmpty {
            for type in Self.readTypes {
                guard let sampleType = type as? HKSampleType else { continue }
                let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completion, error in
                    Task {
                        if error == nil { _ = await handler() }
                        completion()
                    }
                }
                observers.append(query)
                store.execute(query)
            }
        }
        guard enableDelivery else { return true }
        var success = true
        for type in Self.readTypes {
            do { try await store.enableBackgroundDelivery(for: type, frequency: .hourly) }
            catch { success = false }
        }
        return success
    }

    public func changes(for kind: HealthDataKind, anchor: Data?, limit: Int) async throws -> HealthChangeBatch {
        guard isAvailable() else { throw ReaderError.unavailable }
        let cursor: HKQueryAnchor?
        if let anchor {
            guard let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: anchor) else {
                throw ReaderError.invalidAnchor
            }
            cursor = decoded
        } else { cursor = nil }
        let query = HKAnchoredObjectQueryDescriptor(
            predicates: [HKSamplePredicate.sample(type: Self.sampleType(kind))], anchor: cursor, limit: limit)
        let result = try await query.result(for: store)
        try Task.checkCancellation()
        return HealthChangeBatch(added: result.addedSamples.map { Self.reference($0, kind: kind) },
            deleted: result.deletedObjects.map(\.uuid),
            anchor: try NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true),
            hasMore: result.addedSamples.count + result.deletedObjects.count >= limit)
    }

    public func snapshot(for window: HealthImportWindow, calendar: Calendar) async throws -> HealthWindowSnapshot {
        let type = Self.sampleType(window.kind)
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
        let query = HKSampleQueryDescriptor(predicates: [HKSamplePredicate.sample(type: type, predicate: predicate)],
                                            sortDescriptors: [SortDescriptor(\HKSample.startDate)])
        let samples = try await query.result(for: store)
        try Task.checkCancellation()
        let references = samples.map { Self.reference($0, kind: window.kind) }
        var rows: [DeviceMetricRow] = []
        var readings: [MetricReading] = []
        var rejected = 0

        if window.kind == .sleep {
            let sleep = samples.compactMap { sample -> SleepSample? in
                guard let sample = sample as? HKCategorySample else { return nil }
                let stage: SleepStage
                switch sample.value {
                case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: stage = .deep
                case HKCategoryValueSleepAnalysis.asleepREM.rawValue: stage = .rem
                case HKCategoryValueSleepAnalysis.asleepCore.rawValue: stage = .core
                case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: stage = .unspecified
                case HKCategoryValueSleepAnalysis.awake.rawValue: stage = .awake
                case HKCategoryValueSleepAnalysis.inBed.rawValue: stage = .inBed
                default: return nil
                }
                return SleepSample(start: sample.startDate, end: sample.endDate, stage: stage,
                    sourceName: sample.sourceRevision.source.name, sourceVersion: sample.sourceRevision.version,
                    sourceProduct: sample.sourceRevision.productType)
            }
            let summary = SleepMerge.merge(sleep, anchorDate: window.end, calendar: calendar)
            let values: [(String, Double)] = [
                ("sleep_total", summary.totalAsleep), ("sleep_deep", summary.perStage[.deep] ?? 0),
                ("sleep_rem", summary.perStage[.rem] ?? 0), ("sleep_awake", summary.perStage[.awake] ?? 0),
                ("sleep_core", summary.perStage[.core] ?? 0), ("sleep_unspecified", summary.perStage[.unspecified] ?? 0)
            ]
            for (key, seconds) in values where seconds > 0 {
                rows.append(DeviceMetricRow(metricKey: key, value: seconds / 3600, unit: "h",
                    measuredAt: window.start, sourceRef: window.prefix + key,
                    aggregation: .sleepDuration, windowEnd: window.end))
            }
        } else if window.kind == .steps {
            // Cumulative quantities are interval contributions, not running day-to-date counters.
            let statistics = try await HKStatisticsQueryDescriptor(
                predicate: .quantitySample(type: HKQuantityType(.stepCount), predicate: predicate),
                options: .cumulativeSum).result(for: store)
            if statistics == nil && !samples.isEmpty { throw ReaderError.incompleteSnapshot }
            if let value = statistics?.sumQuantity()?.doubleValue(for: .count()), value.isFinite {
                rows.append(DeviceMetricRow(metricKey: "steps", value: value, unit: "count",
                    measuredAt: window.start, sourceRef: window.prefix + "sum",
                    aggregation: .dailySum, windowEnd: min(Date(), window.end)))
            }
        } else if window.kind == .heartRate {
            let unit = HKUnit.count().unitDivided(by: .minute())
            let quantities = samples.compactMap { $0 as? HKQuantitySample }
            let bySource = Dictionary(grouping: quantities) { $0.sourceRevision.source.bundleIdentifier }
            for sourceID in bySource.keys.sorted() {
                guard let contributing = bySource[sourceID] else { continue }
                var points: [HourWindowSample] = []
                for sample in contributing {
                    for point in try await quantityPoints(sample, unit: unit, useEndDate: false) {
                        guard point.at >= window.start, point.at < window.end else { continue }
                        points.append(HourWindowSample(value: point.value, at: point.at))
                    }
                }
                let (summaries, invalid) = HourWindowAggregator.aggregate(points, calendar: calendar)
                rejected += invalid
                guard let summary = summaries.first else { continue }
                let revision = contributing.max { $0.endDate < $1.endDate }?.sourceRevision
                let products = Set(contributing.compactMap { $0.sourceRevision.productType })
                rows.append(DeviceMetricRow(metricKey: "heart_rate", value: summary.avg, unit: "bpm",
                    valueMin: summary.min, valueMax: summary.max, sampleCount: summary.sampleCount, sourceName: revision?.source.name,
                    sourceVersion: revision?.version, sourceProduct: products.count == 1 ? products.first : nil,
                    measuredAt: window.start, sourceRef: window.prefix + sourceID,
                    sourceIdentifier: sourceID, aggregation: .hourlyAverage,
                    windowEnd: min(Date(), window.end)))
            }
        } else {
            let key: String
            let unit: HKUnit
            let label: String
            let factor: Double
            switch window.kind {
            case .restingHeartRate: key = "restingHeartRate"; unit = .count().unitDivided(by: .minute()); label = "bpm"; factor = 1
            case .bloodOxygen: key = "blood_oxygen"; unit = .percent(); label = "%"; factor = 100
            default: key = "respiratory_rate"; unit = .count().unitDivided(by: .minute()); label = "br/min"; factor = 1
            }
            for case let sample as HKQuantitySample in samples {
                let source = sample.sourceRevision
                for point in try await quantityPoints(sample, unit: unit, useEndDate: true) {
                    guard point.at >= window.start, point.at < window.end else { continue }
                    let value = point.value * factor
                    guard value.isFinite else { rejected += 1; continue }
                    // Window-independent identity: a later time-zone/binding change replays onto the same row.
                    let identity = HealthImportWindow.sampleIdentity(kind: window.kind, sampleID: sample.uuid,
                                                                     ordinal: point.ordinal)
                    rows.append(DeviceMetricRow(metricKey: key, value: value, unit: label,
                        sampleCount: 1, sourceName: source.source.name, sourceVersion: source.version,
                        sourceProduct: source.productType, measuredAt: point.at,
                        sourceRef: identity, sourceIdentifier: source.source.bundleIdentifier,
                        aggregation: .sample, windowEnd: point.at))
                    readings.append(MetricReading(metricKey: key, value: value, unit: label, origin: .device,
                        measuredAt: point.at, sourceName: source.source.name, sourceVersion: source.version,
                        sourceProduct: source.productType, sourceIdentifier: source.source.bundleIdentifier,
                        sampleID: identity))
                }
            }
        }
        try Task.checkCancellation()
        return HealthWindowSnapshot(window: window, samples: references, rows: rows, readings: readings, rejected: rejected)
    }

    /// A condensed quantity sample is a container, not one independent reading. `ordinal` is nil for a
    /// single-quantity sample and the series entry index otherwise (identity = sample UUID + ordinal).
    private func quantityPoints(_ sample: HKQuantitySample, unit: HKUnit,
                                useEndDate: Bool) async throws -> [(ordinal: Int?, value: Double, at: Date)] {
        if sample.count == 1 {
            return [(nil, sample.quantity.doubleValue(for: unit),
                     useEndDate ? sample.endDate : sample.startDate)]
        }
        let query = HKQuantitySeriesSampleQueryDescriptor(
            predicate: .quantitySample(type: sample.quantityType, predicate: HKQuery.predicateForObject(with: sample.uuid)),
            options: .orderByQuantitySampleStartDate)
        var points: [(ordinal: Int?, value: Double, at: Date)] = []
        for try await entry in query.results(for: store) {
            try Task.checkCancellation()
            points.append((points.count, entry.quantity.doubleValue(for: unit),
                           useEndDate ? entry.dateInterval.end : entry.dateInterval.start))
        }
        guard points.count == sample.count else { throw ReaderError.incompleteSnapshot }
        return points
    }

    private static func reference(_ sample: HKSample, kind: HealthDataKind) -> HealthSampleReference {
        HealthSampleReference(id: sample.uuid, kind: kind, sourceID: sample.sourceRevision.source.bundleIdentifier,
                              start: sample.startDate, end: sample.endDate)
    }
}
#endif
