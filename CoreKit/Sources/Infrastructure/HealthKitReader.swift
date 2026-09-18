#if os(iOS)
import Foundation
import HealthKit
import Domain
import Protocols

/// Read-only HealthKit adapter. Read authorization is deliberately not observable by apps.
/// 写回（HealthWritingProvider）与读取同体但契约分离——同一 HKHealthStore 实例双协议注入。
public actor HealthKitReader: HealthReadingProvider, HealthWritingProvider {
    private let store: HKHealthStore
    private var observers: [HKObserverQuery] = []
    public init(store: HKHealthStore = HKHealthStore()) { self.store = store }

    /// round2 H3：删 `authorizationDenied`——读取权限对 App 不可观察，「未拒绝」不是证据；
    /// `requestIncomplete` 只表达「系统授权流程尚未完成」这一可观察事实。
    public enum ReaderError: Error { case unavailable, requestIncomplete, invalidAnchor, incompleteSnapshot }

    /// 本应用自己的 bundle 标识（写回防回声：自己写入 HealthKit 的样本不得再导回——
    /// 否则写回样本经增量同步回灌 metric_sample 形成重复行、再写回形成环路）。
    private static let ownBundleID: String? = Bundle.main.bundleIdentifier

    /// 样本是否为本应用写入（防回声过滤；写回关闭时本谓词恒假、零开销）。
    private static func isOwnSample(_ sample: HKSample) -> Bool {
        guard let ownBundleID else { return false }
        return sample.sourceRevision.source.bundleIdentifier == ownBundleID
    }

    public static var readTypes: Set<HKObjectType> {
        var types = Set(HealthDataKind.allCases.map { sampleType($0) as HKObjectType })
        // 特征型（血型/出生日期/生理性别）：**读**集合里声明即可（写集合里放特征型不会出现在授权单上）；
        // 用户未填不报错，读取时抛错由 characteristics() 如实转成 nil。
        types.formUnion(Self.characteristicTypes)
        return types
    }

    private static var characteristicTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for identifier: HKCharacteristicTypeIdentifier in [.bloodType, .dateOfBirth, .biologicalSex] {
            if let type = HKObjectType.characteristicType(forIdentifier: identifier) { types.insert(type) }
        }
        return types
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

    // MARK: - 写回（业主 2026-09-17 定：本机确认的手输指标 → HealthKit）

    /// 可写类型 = Domain `HealthWriteBack.canonicalUnit` 的指标集（单位匹配的唯一对照）。
    public static var writeTypes: Set<HKSampleType> {
        Set([MetricType.bloodPressureSys, .bloodPressureDia, .glucose, .weight,
             .temperature, .heartRate, .bloodOxygen].compactMap { hkQuantityType($0) as HKSampleType? })
    }

    private static func hkQuantityType(_ metric: MetricType) -> HKQuantityType? {
        switch metric {
        case .bloodPressureSys: return HKQuantityType(.bloodPressureSystolic)
        case .bloodPressureDia: return HKQuantityType(.bloodPressureDiastolic)
        case .glucose: return HKQuantityType(.bloodGlucose)
        case .weight: return HKQuantityType(.bodyMass)
        case .temperature: return HKQuantityType(.bodyTemperature)
        case .heartRate: return HKQuantityType(.heartRate)
        case .bloodOxygen: return HKQuantityType(.oxygenSaturation)
        default: return nil
        }
    }

    private static func hkUnit(_ metric: MetricType) -> HKUnit? {
        switch metric {
        case .bloodPressureSys, .bloodPressureDia: return .millimeterOfMercury()
        case .glucose: return .gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        case .weight: return .gramUnit(with: .kilo)
        case .temperature: return .degreeCelsius()
        case .heartRate: return .count().unitDivided(by: .minute())
        case .bloodOxygen: return .percent()
        default: return nil
        }
    }

    /// 写回尺度：**应用内部值 → HealthKit 单位期望值**。规则本体在 Domain
    /// `HealthWriteBack.writeScale`（与 `canonicalUnit`/`isWritable` 同一出口，且本机可测）；
    /// 此处只做 `MetricType` → metric 字符串的转接。
    private static func hkWriteScale(_ metric: MetricType) -> Double {
        HealthWriteBack.writeScale(for: metric.rawValue)
    }

    public func requestWriteAuthorization() async throws {
        guard isAvailable() else { throw HealthWriteError.unavailable }
        try await store.requestAuthorization(toShare: Self.writeTypes, read: [])
        // 同读取侧纪律：只回答「流程是否已完成」；是否获准由 writeAuthorizationStatus() 观察。
        let status = try await store.statusForAuthorizationRequest(toShare: Self.writeTypes, read: [])
        guard status == .unnecessary else { throw HealthWriteError.requestIncomplete }
    }

    public func writeAuthorizationStatus() async -> HealthWriteAuthStatus {
        guard isAvailable() else { return .notDetermined }
        var anyDenied = false
        var allGranted = true
        for type in Self.writeTypes {
            switch store.authorizationStatus(for: type) {
            case .sharingAuthorized: break
            case .sharingDenied: anyDenied = true; allGranted = false
            default: allGranted = false
            }
        }
        if allGranted { return .granted }
        return anyDenied ? .denied : .notDetermined
    }

    /// 写回样本。单位不符/类型不可写的条目**跳过**（Domain `HealthWriteBack.isWritable`
    /// 单一事实源）；收缩压携第二值时合并为血压相关性对象（Health 里的规范呈现形态），
    /// 其余写入单值样本。只返回实际写入条数。
    public func writeBack(_ samples: [HealthSampleDraft]) async throws -> Int {
        guard isAvailable() else { throw HealthWriteError.unavailable }
        var objects: [HKObject] = []
        var written = 0
        for draft in samples {
            guard draft.measuredAt.timeIntervalSince1970.isFinite,
                  HealthWriteBack.isWritable(metric: draft.metric, unit: draft.unit, value: draft.value),
                  let metric = MetricType(rawValue: draft.metric) else { continue }
            let date = draft.measuredAt
            if metric == .bloodPressureSys, let dia = draft.secondaryValue, dia.isFinite {
                guard let sysType = Self.hkQuantityType(.bloodPressureSys),
                      let diaType = Self.hkQuantityType(.bloodPressureDia) else { continue }
                let sys = HKQuantitySample(type: sysType,
                    quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: draft.value),
                    start: date, end: date)
                let diaSample = HKQuantitySample(type: diaType,
                    quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: dia),
                    start: date, end: date)
                objects.append(HKCorrelation(type: HKCorrelationType(.bloodPressure),
                                             start: date, end: date,
                                             objects: Set<HKSample>(arrayLiteral: sys, diaSample)))
                written += 1
            } else {
                guard let type = Self.hkQuantityType(metric), let unit = Self.hkUnit(metric) else { continue }
                objects.append(HKQuantitySample(type: type,
                    quantity: HKQuantity(unit: unit,
                                         doubleValue: draft.value * Self.hkWriteScale(metric)),
                    start: date, end: date))
                written += 1
            }
        }
        guard !objects.isEmpty else { return 0 }
        do {
            try await store.save(objects)
            return written
        } catch let error as HKError {
            throw error.code == .errorAuthorizationNotDetermined ? HealthWriteError.requestIncomplete
                                                                  : HealthWriteError.failed
        } catch {
            throw HealthWriteError.failed
        }
    }

    public func isAvailable() -> Bool { HKHealthStore.isHealthDataAvailable() }

    public func requestAuthorization() async throws {
        guard isAvailable() else { throw ReaderError.unavailable }
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
        // round2 H3：statusForAuthorizationRequest 只回答「系统流程是否已完成」
        // （.unnecessary = 已完成、.shouldRequest = 未完成）。读取权限对 App 不可观察：
        // 完成 ≠ 获准，未完成 ≠ 拒绝——旧实现把 .unnecessary 当「未拒绝」证据并把其余
        // 映射成 authorizationDenied，两者皆为臆断。这里只如实上报「流程未完成」。
        let status = try await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes)
        guard status == .unnecessary else { throw ReaderError.requestIncomplete }
    }

    /// 仅特征型的授权请求（首启注册预填的最小请求——系统授权单只出现健康档案资料）。
    public func requestCharacteristicAuthorization() async throws {
        guard isAvailable() else { throw ReaderError.unavailable }
        try await store.requestAuthorization(toShare: [], read: Self.characteristicTypes)
        let status = try await store.statusForAuthorizationRequest(toShare: [], read: Self.characteristicTypes)
        guard status == .unnecessary else { throw ReaderError.requestIncomplete }
    }

    /// 特征型读取（业主 2026-09-17 定：导入走档案候选）。
    ///
    /// **用户没填 ≠ 失败**：Health 里未设置时 `bloodType()` 等会抛错——那是「没有这份数据」，
    /// 如实按 nil 呈现，绝不编造、绝不猜（来源与精度都随 Health 的填法）。
    public func characteristics() async throws -> HealthCharacteristics {
        guard isAvailable() else { throw ReaderError.unavailable }
        var result = HealthCharacteristics()
        do { result.bloodType = Self.format(try store.bloodType().bloodType) } catch { result.bloodType = nil }
        do { result.gender = Self.format(try store.biologicalSex().biologicalSex) } catch { result.gender = nil }
        do { result.birthDate = Self.format(try store.dateOfBirthComponents()) } catch { result.birthDate = nil }
        return result
    }

    /// 血型：国际简写（`A+` / `AB−`…）。Health 的 `.notSet` 归 nil。
    private static func format(_ blood: HKBloodType) -> String? {
        switch blood {
        case .aPositive: return "A+"
        case .aNegative: return "A−"
        case .bPositive: return "B+"
        case .bNegative: return "B−"
        case .abPositive: return "AB+"
        case .abNegative: return "AB−"
        case .oPositive: return "O+"
        case .oNegative: return "O−"
        default: return nil
        }
    }

    /// 生理性别：Health 三档原样透传（`male` / `female` / `other`），到档案前由用户确认。
    private static func format(_ sex: HKBiologicalSex) -> String? {
        switch sex {
        case .male: return "male"
        case .female: return "female"
        case .other: return "other"
        default: return nil
        }
    }

    /// 出生日期：`yyyy-MM-dd`；Health 里只填了年份时给 `yyyy`（精度随来源，不擅自细化）。
    private static func format(_ components: DateComponents) -> String? {
        guard let year = components.year else { return nil }
        guard let month = components.month, let day = components.day else { return String(format: "%04d", year) }
        return String(format: "%04d-%02d-%02d", year, month, day)
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

    /// round2 H-N1：按分道谓词分页——HKAnchoredObjectQuery 行序最旧优先且不可倒序，
    /// 近一年先到的唯一手段是把谓词限定在近一年；每道各持独立锚点（调用方按 lane 存取）。
    public func changes(for kind: HealthDataKind, scope: HealthFetchScope, anchor: Data?, limit: Int) async throws -> HealthChangeBatch {
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
            predicates: [HKSamplePredicate.sample(type: Self.sampleType(kind), predicate: Self.changePredicate(for: scope))],
            anchor: cursor, limit: limit)
        let result = try await query.result(for: store)
        try Task.checkCancellation()
        // 审查修复：added+deleted 合计超限即抛错——limit 只约束新增样本页，
        // 删除对象随锚点窗口整体返回。新增满页（500）且用户删过 1 条样本
        // 时恒抛 incompleteSnapshot、锚点永不前进、同批删除每轮重报——
        // 该类型从此永久卡死（无恢复路径）。分页只看 added，deleted 不
        // 参与限流判定。
        guard result.addedSamples.count <= limit else { throw ReaderError.incompleteSnapshot }
        // 防回声：自己写回 HealthKit 的样本不进增量通道；其墓碑一并过滤——
        // 写回样本从未入库，对应的删除证明无窗口可重算、纯属浪费。
        let ownSampleIDs = Set(result.addedSamples.filter(Self.isOwnSample).map(\.uuid))
        return HealthChangeBatch(added: try result.addedSamples
            .filter { !Self.isOwnSample($0) }.map { try Self.reference($0, kind: kind) },
            deleted: result.deletedObjects.filter { !ownSampleIDs.contains($0.uuid) }.map(\.uuid),
            anchor: try NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true),
            // One additional empty query establishes exhaustion even when a page is mostly deletions.
            hasMore: !result.addedSamples.isEmpty || !result.deletedObjects.isEmpty)
    }

    public func snapshot(for window: HealthImportWindow, calendar: Calendar) async throws -> HealthWindowSnapshot {
        try Task.checkCancellation()
        guard isAvailable() else { throw ReaderError.unavailable }
        guard window.isValid else { throw ReaderError.incompleteSnapshot }
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
        // 防回声：窗口聚合同样排除自己写回的样本（否则小时均值/步数合计被自己的写回抬高）。
        let samples = try await querySamples(for: window.kind, predicate: predicate)
            .filter { !Self.isOwnSample($0) }
        let references = try samples.map { try Self.reference($0, kind: window.kind) }
        var rows: [DeviceMetricRow] = []
        var readings: [MetricReading] = []
        var rejected = 0
        var sparse = 0   // round2 H-N2：心率 <3 样本未成行的小时桶计数（按来源逐桶）

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
                // 验证集与索引快照同口径过滤自己的写回样本——谓词只按时间窗匹配，
                // 不过滤时验证集多出的自有样本会让集合比对误判 incompleteSnapshot。
                let verified = try await querySamples(for: .steps, predicate: statisticsPredicate)
                    .filter { !Self.isOwnSample($0) }
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
                let aggregate = HourWindowAggregator.aggregate(points, calendar: calendar)
                rejected += aggregate.rejected
                sparse += aggregate.sparseWindows
                guard let summary = aggregate.windows.first else { continue }
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
        return HealthWindowSnapshot(window: window, samples: references, rows: rows, readings: readings,
                                    rejected: rejected, sparseWindows: sparse)
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

    /// round2 H-N1 分道谓词：recent = end >= cutoff（默认选项左闭）；history = end < cutoff
    /// （.strictEndDate 右开）。两道互补覆盖全部样本，边界样本恰出现一次。墓碑不携日期，
    /// HealthKit 可能在两道都回报同一 UUID——commit 幂等（首道删索引后第二道成为
    /// 「纯删除且无窗口受影响」空页，安全排空）。边界语义与 Domain `HealthFetchScope.matches`
    /// 一致，由 HealthKitReaderPredicateTests 在 CI 实证。
    static func changePredicate(for scope: HealthFetchScope) -> NSPredicate {
        switch scope.lane {
        case .recent:
            return HKQuery.predicateForSamples(withStart: scope.cutoff, end: nil, options: [])
        case .history:
            return HKQuery.predicateForSamples(withStart: nil, end: scope.cutoff, options: [.strictEndDate])
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
