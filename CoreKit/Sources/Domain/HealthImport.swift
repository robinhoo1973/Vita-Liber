import Foundation

/// HealthKit identities are not medical values. They make deletion and replay recoverable.
public enum HealthDataKind: String, CaseIterable, Codable, Sendable {
    case heartRate, restingHeartRate, bloodOxygen, respiratoryRate, steps, sleep
}

public enum MetricAggregation: String, Codable, Sendable {
    case sample, hourlyAverage, dailySum, sleepDuration
}

public struct HealthSampleReference: Sendable, Equatable, Codable {
    public let id: UUID
    public let kind: HealthDataKind
    public let sourceID: String
    public let start: Date
    public let end: Date
    public init(id: UUID, kind: HealthDataKind, sourceID: String, start: Date, end: Date) {
        self.id = id; self.kind = kind; self.sourceID = sourceID
        self.start = start; self.end = end
    }

    public var isValid: Bool {
        !sourceID.isEmpty && HealthImportWindow.validDates(start: start, end: end)
    }
}

public struct HealthChangeBatch: Sendable, Equatable, Codable {
    public let added: [HealthSampleReference]
    public let deleted: [UUID]
    public let anchor: Data
    public let hasMore: Bool
    public init(added: [HealthSampleReference], deleted: [UUID], anchor: Data, hasMore: Bool) {
        self.added = added; self.deleted = deleted; self.anchor = anchor; self.hasMore = hasMore
    }
}

public extension HealthDataKind {
    var primaryMetric: MetricType {
        switch self {
        case .heartRate: return .heartRate
        case .restingHeartRate: return .restingHeartRate
        case .bloodOxygen: return .bloodOxygen
        case .respiratoryRate: return .respiratoryRate
        case .steps: return .steps
        case .sleep: return .sleepTotal
        }
    }
    /// Aggregate kinds project one row per window (hour / day / night); discrete kinds keep one row per reading.
    var isAggregated: Bool { [.heartRate, .steps, .sleep].contains(self) }

    /// 反查（2026-09-16 业主实测）：`metric_sample.metric_key`（设备行 = `primaryMetric.rawValue`）
    /// → 数据类别。健康档案的设备行据此路由到**该类型的数据列表页**（详细数据 + 趋势入口），
    /// 而不是直跳趋势图（业主第 5 项：「直接进入趋势图感觉突兀」）。非设备类别键 → nil。
    static func forMetricKey(_ key: String) -> HealthDataKind? {
        allCases.first { $0.primaryMetric.rawValue == key }
    }
}

public struct HealthImportWindow: Sendable, Hashable, Codable {
    public let kind: HealthDataKind
    public let start: Date
    public let end: Date
    /// Window-scoped prefix. Aggregate rows embed the window start because the window *is* their identity.
    public var prefix: String { "hk:\(kind.rawValue):\(Int64(start.timeIntervalSince1970)):" }
    /// Identity prefix used to find this window's rows: discrete readings are identified by sample UUID
    /// only, so a later calendar/time-zone change replays onto the same row instead of duplicating it.
    public var identityPrefix: String { kind.isAggregated ? prefix : "hk:\(kind.rawValue):" }
    public init(kind: HealthDataKind, start: Date, end: Date) {
        self.kind = kind; self.start = start; self.end = end
    }

    public var isValid: Bool { Self.validDates(start: start, end: end) && end > start }

    fileprivate static func validDates(start: Date, end: Date) -> Bool {
        let lower = start.timeIntervalSince1970
        let upper = end.timeIntervalSince1970
        return lower.isFinite && upper.isFinite && end >= start
            && lower >= Double(Int64.min) && upper < Double(Int64.max)
    }

    /// Matches HealthKit's default sample predicate, including a sample ending at the lower boundary.
    public func overlaps(_ sample: HealthSampleReference) -> Bool {
        sample.kind == kind && sample.end >= start && sample.start < end
    }

    /// Stable identity of one discrete reading (`ordinal` distinguishes entries of a quantity series).
    public static func sampleIdentity(kind: HealthDataKind, sampleID: UUID, ordinal: Int?) -> String {
        let base = "hk:\(kind.rawValue):\(sampleID.uuidString)"
        return ordinal.map { "\(base):\($0)" } ?? base
    }

    /// Inverse of `sampleIdentity`; nil for aggregate identities or foreign formats.
    public static func sampleID(fromIdentity identity: String, kind: HealthDataKind) -> UUID? {
        guard !kind.isAggregated else { return nil }
        let head = "hk:\(kind.rawValue):"
        guard identity.hasPrefix(head) else { return nil }
        let rest = identity.dropFirst(head.count)
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let id = UUID(uuidString: String(parts[0])) else { return nil }
        if parts.count == 2 {
            guard let ordinal = Int(parts[1]), ordinal >= 0 else { return nil }
        }
        return id
    }

    /// Whether a projected row belongs to this window: aggregate rows by prefix, discrete rows by
    /// identity prefix plus half-open `measuredAt` membership.
    public func contains(sourceRef: String, measuredAt: Date) -> Bool {
        guard isValid, measuredAt.timeIntervalSince1970.isFinite,
              sourceRef.hasPrefix(identityPrefix) else { return false }
        if kind.isAggregated { return measuredAt == start }
        return Self.sampleID(fromIdentity: sourceRef, kind: kind) != nil
            && measuredAt >= start && measuredAt < end
    }

    public static func covering(_ sample: HealthSampleReference, calendar: Calendar) -> [Self] {
        guard sample.isValid else { return [] }
        var result: [Self] = []
        // Steps/sleep intervals end exclusively on a boundary; a heart-rate series may carry its last
        // instantaneous entry exactly at `end`, so that hour must be covered too (closed end).
        let isInterval = [.steps, .sleep].contains(sample.kind)
        var cursor = sample.start
        repeat {
            let start: Date
            let end: Date
            if sample.kind == .heartRate {
                guard let interval = calendar.dateInterval(of: .hour, for: cursor) else { return [] }
                start = interval.start; end = interval.end
            } else if sample.kind == .sleep {
                guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: cursor),
                      let previous = calendar.date(byAdding: .day, value: -1, to: noon) else { return [] }
                start = cursor < noon ? previous : noon
                guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
                end = next
            } else {
                start = calendar.startOfDay(for: cursor)
                guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
                end = next
            }
            let window = Self(kind: sample.kind, start: start, end: end)
            guard window.isValid, end > cursor else { return [] }
            result.append(window)
            cursor = end
        } while cursor < sample.end || (!isInterval && cursor == sample.end)
        return result
    }
}

public struct HealthWindowSnapshot: Sendable {
    public let window: HealthImportWindow
    public let samples: [HealthSampleReference]
    public let rows: [DeviceMetricRow]
    public let readings: [MetricReading]
    public let rejected: Int
    /// round2 H-N2：本窗口内 <minSamples 未成统计行的小时桶数（心率）；其余类型恒 0
    public let sparseWindows: Int
    public init(window: HealthImportWindow, samples: [HealthSampleReference],
                rows: [DeviceMetricRow], readings: [MetricReading] = [], rejected: Int = 0,
                sparseWindows: Int = 0) {
        self.window = window; self.samples = samples; self.rows = rows
        self.readings = readings; self.rejected = rejected; self.sparseWindows = sparseWindows
    }
}

/// F16 同步轮报告（结构轮 2026-09-15：自 Infrastructure/HealthKitSyncService.swift 迁入）——
/// 纯 Codable 值对象，表现层读模型（HealthImportDashboard.lastReport）与持久化
/// （hk_import_status.report_json）共用；此前 UI 依赖 Infrastructure 内部类型（P7）。
public struct SyncReport: Sendable, Equatable, Codable {
    public var elevated: Int = 0 // Scheduled, not delivered.
    public var noRangeCount: Int = 0
    public var persistedRows: Int = 0 // Includes updates and removals.
    public var preservedRows: Int = 0 // Unowned recovered facts left unchanged.
    public var deferredWindows: Int = 0 // Incomplete visibility; pending work is retained.
    /// Added + deleted references HealthKit reported this round. Zero with no failures means
    /// "nothing readable changed" — not "denied" and not "no history" (read authorization is opaque).
    public var receivedChanges: Int = 0
    public var rejectedSamples: Int = 0
    public var failedTypes: [HealthDataKind] = []
    public var hasMore = false
    public var notificationFailures = 0
    public var lastSyncAt: Date
    public var bindingId: UUID? = nil
    public var patientId: UUID? = nil
    // round2 H-N1/H-N2 进度字段——全部 Optional：`hk_import_status.report_json` 旧 JSON 无键必须可解码
    // （合成 Decodable 对非 Optional 缺键即抛）。
    /// H-N2：本轮 <3 样本未成行的小时桶数（统计事实，非阈值判定）
    public var sparseWindows: Int? = nil
    /// H-N1：本轮后仍待物化的窗口数（排空进度）
    public var remainingWindows: Int? = nil
    /// H-N1：本轮推进的道；nil = 无在途工作
    public var backfillLane: HealthFetchLane? = nil
    /// 2026-09-19 审查修复（业主诉求：类别卡导入进度条）：按类型细分剩余窗口数；
    /// Optional——旧 report_json 无此键必须可解码。
    public var perKindRemaining: [String: Int]? = nil

    /// 跨模块构造出口（结构轮 2026-09-15 修复）：合成 memberwise init 为 internal，
    /// 迁入 Domain 后 Infrastructure 调用方不可见——显式 public init 兜底。
    public init(lastSyncAt: Date,
                elevated: Int = 0, noRangeCount: Int = 0, persistedRows: Int = 0,
                preservedRows: Int = 0, deferredWindows: Int = 0, receivedChanges: Int = 0,
                rejectedSamples: Int = 0, failedTypes: [HealthDataKind] = [],
                hasMore: Bool = false, notificationFailures: Int = 0,
                bindingId: UUID? = nil, patientId: UUID? = nil,
                sparseWindows: Int? = nil, remainingWindows: Int? = nil,
                backfillLane: HealthFetchLane? = nil,
                perKindRemaining: [String: Int]? = nil) {
        self.elevated = elevated; self.noRangeCount = noRangeCount
        self.persistedRows = persistedRows; self.preservedRows = preservedRows
        self.deferredWindows = deferredWindows; self.receivedChanges = receivedChanges
        self.rejectedSamples = rejectedSamples; self.failedTypes = failedTypes
        self.hasMore = hasMore; self.notificationFailures = notificationFailures
        self.lastSyncAt = lastSyncAt; self.bindingId = bindingId; self.patientId = patientId
        self.sparseWindows = sparseWindows; self.remainingWindows = remainingWindows
        self.backfillLane = backfillLane
        self.perKindRemaining = perKindRemaining
    }
}

