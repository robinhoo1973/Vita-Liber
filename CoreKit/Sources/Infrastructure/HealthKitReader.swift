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

    public enum ReaderError: Error { case unavailable, authorizationDenied, invalidAnchor, incompleteSnapshot }

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
        // 拒绝核验（FR14.1 对偶纪律）：requestAuthorization 对「用户拒绝」静默
        // 完成（不抛错），不二次确认会以「已连接」落库而每次查询都
        // authorizationDenied——拒绝必须即时反映，绝不伪装成授权成功。
        let status: HKAuthorizationRequestStatus
        do {
            status = try await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes)
        } catch {
            throw ReaderError.authorizationDenied
        }
        guard status == .unnecessary else { throw ReaderError.authorizationDenied }
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
        if !enableDelivery {
            var success = true
            for type in Self.readTypes {
                do { try await store.disableBackgroundDelivery(for: type) }
                catch { success = false }
            }
            return success
        }
        var success = true
        for type in Self.readTypes {
            do { try await store.enableBackgroundDelivery(for: type, frequency: .hourly) }
            catch { success = false }
        }
        return success
    }

    public func changes(for kind: HealthDataKind, anchor: Data?, limit: Int) async throws -> HealthChangeBatch {
        try Task.checkCancellation()
        guard isAvailable() else { throw ReaderError.unavailable }
        guard limit > 0, limit <= 500 else { throw ReaderError.incompleteSnapshot }
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
        // 审查修复：added+deleted 合计超限即抛错——limit 只约束新增样本页，
        // 删除对象随锚点窗口整体返回。新增满页（500）且用户删过 1 条样本
        // 时恒抛 incompleteSnapshot、锚点永不前进、同批删除每轮重报——
        // 该类型从此永久卡死（无恢复路径）。分页只看 added，deleted 不
        // 参与限流判定。
        guard result.addedSamples.count <= limit else { throw ReaderError.incompleteSnapshot }
        return HealthChangeBatch(added: try result.addedSamples.map { try Self.reference($0, kind: kind) },
            deleted: result.deletedObjects.map(\.uuid),
            anchor: try NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true),
            // One additional empty query establishes exhaustion even when a page is mostly deletions.
            hasMore: !result.addedSamples.isEmpty || !result.deletedObjects.isEmpty)
    }

    public func snapshot(for window: HealthImportWindow, calendar: Calendar) async throws -> HealthWindowSnapshot {
        try Task.checkCancellation()
        guard isAvailable() else { throw ReaderError.unavailable }
        guard window.isValid else { throw ReaderError.incompleteSnapshot }
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
        let samples = try await querySamples(for: window.kind, predicate: predicate)
        let references = try samples.map { try Self.reference($0, kind: window.kind) }
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
            if !samples.isEmpty {
                let ids = Set(samples.map(\.uuid))
                let statisticsPredicate = Self.stepStatisticsPredicate(for: window, sampleIDs: ids)
                try Task.checkCancellation()
                // Keep HealthKit's source arbitration, but never include a contributor absent from the index snapshot.
                let statistics = try await HKStatisticsQueryDescriptor(
                    predicate: .quantitySample(type: HKQuantityType(.stepCount), predicate: statisticsPredicate),
                    options: .cumulativeSum).result(for: store)
                try Task.checkCancellation()
                guard let value = statistics?.sumQuantity()?.doubleValue(for: .count()), value.isFinite else {
                    throw ReaderError.incompleteSnapshot
                }
                let verified = try await querySamples(for: .steps, predicate: statisticsPredicate)
                guard Set(verified.map(\.uuid)) == ids else { throw ReaderError.incompleteSnapshot }
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
        try Task.checkCancellation()
        guard sample.count > 0 else { throw ReaderError.incompleteSnapshot }
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
            guard entry.dateInterval.start.timeIntervalSince1970.isFinite,
                  entry.dateInterval.end.timeIntervalSince1970.isFinite,
                  entry.dateInterval.start >= sample.startDate, entry.dateInterval.end <= sample.endDate else {
                throw ReaderError.incompleteSnapshot
            }
            points.append((points.count, entry.quantity.doubleValue(for: unit),
                           useEndDate ? entry.dateInterval.end : entry.dateInterval.start))
        }
        guard points.count == sample.count else { throw ReaderError.incompleteSnapshot }
        return points
    }

    /// Every reference query is bounded, without truncating a window or slicing an opaque anchor.
    private func querySamples(for kind: HealthDataKind, predicate: NSPredicate) async throws -> [HKSample] {
        var samples: [UUID: HKSample] = [:]
        var anchor: HKQueryAnchor?
        while true {
            try Task.checkCancellation()
            let query = HKAnchoredObjectQueryDescriptor(
                predicates: [.sample(type: Self.sampleType(kind), predicate: predicate)], anchor: anchor, limit: 500)
            let result = try await query.result(for: store)
            try Task.checkCancellation()
            guard result.addedSamples.count <= 500 else { throw ReaderError.incompleteSnapshot }
            for sample in result.addedSamples { samples[sample.uuid] = sample }
            for deleted in result.deletedObjects { samples.removeValue(forKey: deleted.uuid) }
            if result.addedSamples.isEmpty && result.deletedObjects.isEmpty { break }
            if let anchor, result.newAnchor.isEqual(anchor) { throw ReaderError.invalidAnchor }
            anchor = result.newAnchor
        }
        return samples.values.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.uuid.uuidString < $1.uuid.uuidString
        }
    }

    static func stepStatisticsPredicate(for window: HealthImportWindow, sampleIDs: Set<UUID>) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: []),
            HKQuery.predicateForObjects(with: sampleIDs)
        ])
    }

    private static func reference(_ sample: HKSample, kind: HealthDataKind) throws -> HealthSampleReference {
        let ref = HealthSampleReference(id: sample.uuid, kind: kind, sourceID: sample.sourceRevision.source.bundleIdentifier,
                                       start: sample.startDate, end: sample.endDate)
        guard ref.isValid else { throw ReaderError.incompleteSnapshot }
        return ref
    }
}
#endif
